/* ==================== keyfilter.c (물리 PC 지원 버전) ==================== */

#include <ntddk.h>
#include <wdm.h>
#include <ntstrsafe.h>
#include "keyfilter.h"

/* 상수 */
#define DEVICE_NAME      L"\\Device\\KeyFilter"
#define SYMLINK_NAME     L"\\DosDevices\\KeyFilter"
#define POOL_TAG         'KFLG'

/* 전역 공유 로그 버퍼 (모든 필터 디바이스가 공유) */
static KEY_RECORD   g_LogBuffer[LOG_CAPACITY];
static ULONG        g_LogHead = 0;
static ULONG        g_LogTail = 0;
static KSPIN_LOCK   g_LogLock;

/* 디바이스 익스텐션 — LowerDevice만 유지 */
typedef struct _DEVICE_EXTENSION {
    PDEVICE_OBJECT  LowerDevice;
} DEVICE_EXTENSION, *PDEVICE_EXTENSION;

/* 전방 선언 */
DRIVER_UNLOAD           DriverUnload;
DRIVER_DISPATCH         DispatchPassThrough;
DRIVER_DISPATCH         DispatchRead;
DRIVER_DISPATCH         DispatchControl;
IO_COMPLETION_ROUTINE   ReadCompletion;

/* ================================================================
 * LogKeystroke — 전역 링 버퍼에 키스트로크 저장
 * ================================================================ */
static VOID LogKeystroke(USHORT UnitId, USHORT MakeCode, USHORT Flags)
{
    KIRQL oldIrql;
    ULONG nextTail;

    KeAcquireSpinLock(&g_LogLock, &oldIrql);

    g_LogBuffer[g_LogTail].UnitId   = UnitId;
    g_LogBuffer[g_LogTail].MakeCode = MakeCode;
    g_LogBuffer[g_LogTail].Flags    = Flags;
    g_LogBuffer[g_LogTail].Reserved = 0;
    KeQuerySystemTime(&g_LogBuffer[g_LogTail].Timestamp);

    nextTail = (g_LogTail + 1) % LOG_CAPACITY;

    /* 가득 찼으면 가장 오래된 항목을 덮어씀 */
    if (nextTail == g_LogHead)
        g_LogHead = (g_LogHead + 1) % LOG_CAPACITY;

    g_LogTail = nextTail;

    KeReleaseSpinLock(&g_LogLock, oldIrql);
}

/* ================================================================
 * ReadCompletion — IRP_MJ_READ 완료 루틴
 * [실행 컨텍스트] IRQL <= DISPATCH_LEVEL
 * ================================================================ */
NTSTATUS ReadCompletion(
    PDEVICE_OBJECT DeviceObject,
    PIRP           Irp,
    PVOID          Context)
{
    PKEYBOARD_INPUT_DATA data;
    ULONG i, numKeys;

    UNREFERENCED_PARAMETER(DeviceObject);
    UNREFERENCED_PARAMETER(Context);

    if (Irp->IoStatus.Status == STATUS_SUCCESS) {
        data    = (PKEYBOARD_INPUT_DATA)Irp->AssociatedIrp.SystemBuffer;
        numKeys = (ULONG)(Irp->IoStatus.Information / sizeof(KEYBOARD_INPUT_DATA));

        for (i = 0; i < numKeys; i++) {
            LogKeystroke(data[i].UnitId, data[i].MakeCode, data[i].Flags);
        }
    }

    if (Irp->PendingReturned)
        IoMarkIrpPending(Irp);

    return Irp->IoStatus.Status;
}

/* ================================================================
 * DispatchRead — IRP_MJ_READ 핸들러 (필터 디바이스 전용)
 * ================================================================ */
NTSTATUS DispatchRead(PDEVICE_OBJECT DeviceObject, PIRP Irp)
{
    PDEVICE_EXTENSION ext = (PDEVICE_EXTENSION)DeviceObject->DeviceExtension;

    if (ext == NULL || ext->LowerDevice == NULL) {
        Irp->IoStatus.Status      = STATUS_INVALID_DEVICE_REQUEST;
        Irp->IoStatus.Information = 0;
        IoCompleteRequest(Irp, IO_NO_INCREMENT);
        return STATUS_INVALID_DEVICE_REQUEST;
    }

    IoCopyCurrentIrpStackLocationToNext(Irp);
    IoSetCompletionRoutine(Irp, ReadCompletion, NULL, TRUE, TRUE, TRUE);
    return IoCallDriver(ext->LowerDevice, Irp);
}

/* ================================================================
 * DispatchControl — IOCTL 핸들러 (메인 디바이스용)
 * METHOD_BUFFERED: SystemBuffer 하나를 입출력 공유
 * ================================================================ */
NTSTATUS DispatchControl(PDEVICE_OBJECT DeviceObject, PIRP Irp)
{
    PIO_STACK_LOCATION  stack  = IoGetCurrentIrpStackLocation(Irp);
    NTSTATUS            status = STATUS_SUCCESS;
    ULONG_PTR           info   = 0;
    KIRQL               oldIrql;
    PKEY_RECORD         outBuf;
    ULONG               outLen, capacity, i;

    UNREFERENCED_PARAMETER(DeviceObject);

    switch (stack->Parameters.DeviceIoControl.IoControlCode) {

    case IOCTL_KEYFILTER_READ:
        outBuf   = (PKEY_RECORD)Irp->AssociatedIrp.SystemBuffer;
        outLen   = stack->Parameters.DeviceIoControl.OutputBufferLength;
        capacity = outLen / sizeof(KEY_RECORD);

        KeAcquireSpinLock(&g_LogLock, &oldIrql);

        for (i = 0; i < capacity && g_LogHead != g_LogTail; i++) {
            outBuf[i] = g_LogBuffer[g_LogHead];
            g_LogHead = (g_LogHead + 1) % LOG_CAPACITY;
        }

        KeReleaseSpinLock(&g_LogLock, oldIrql);
        info = (ULONG_PTR)(i * sizeof(KEY_RECORD));
        break;

    default:
        status = STATUS_INVALID_DEVICE_REQUEST;
        break;
    }

    Irp->IoStatus.Status      = status;
    Irp->IoStatus.Information = info;
    IoCompleteRequest(Irp, IO_NO_INCREMENT);
    return status;
}

/* ================================================================
 * DispatchPassThrough — 나머지 IRP 패스스루
 * 메인 컨트롤 디바이스(DeviceExtension=NULL)는 성공으로 완료
 * ================================================================ */
NTSTATUS DispatchPassThrough(PDEVICE_OBJECT DeviceObject, PIRP Irp)
{
    PDEVICE_EXTENSION ext = (PDEVICE_EXTENSION)DeviceObject->DeviceExtension;

    if (ext == NULL || ext->LowerDevice == NULL) {
        /* 메인 컨트롤 디바이스 — CREATE/CLOSE 등은 성공으로 완료 */
        Irp->IoStatus.Status      = STATUS_SUCCESS;
        Irp->IoStatus.Information = 0;
        IoCompleteRequest(Irp, IO_NO_INCREMENT);
        return STATUS_SUCCESS;
    }

    IoSkipCurrentIrpStackLocation(Irp);
    return IoCallDriver(ext->LowerDevice, Irp);
}

/* ================================================================
 * AttachToOneKeyboard — 하나의 KeyboardClassN에 안전하게 attach
 * ================================================================ */
static NTSTATUS AttachToOneKeyboard(
    PDRIVER_OBJECT DriverObject,
    PCWSTR DeviceNameStr)
{
    UNICODE_STRING    kbdName;
    PDEVICE_OBJECT    filterDev = NULL;
    PDEVICE_OBJECT    targetDev = NULL;
    PFILE_OBJECT      fileObj   = NULL;
    PDEVICE_EXTENSION ext;
    NTSTATUS          status;

    RtlInitUnicodeString(&kbdName, DeviceNameStr);

    /* 대상 디바이스 객체 포인터 획득 (존재하지 않으면 조용히 건너뜀) */
    status = IoGetDeviceObjectPointer(&kbdName, FILE_READ_DATA, &fileObj, &targetDev);
    if (!NT_SUCCESS(status))
        return status;

    status = IoCreateDevice(
        DriverObject,
        sizeof(DEVICE_EXTENSION),
        NULL,                       /* 이름 없이 생성 (여러 개 만들기 때문) */
        FILE_DEVICE_KEYBOARD,
        0,
        FALSE,
        &filterDev);

    if (!NT_SUCCESS(status)) {
        DbgPrint("[KeyFilter] IoCreateDevice 실패 (%ws): 0x%08X\n", DeviceNameStr, status);
        ObDereferenceObject(fileObj);
        return status;
    }

    ext = (PDEVICE_EXTENSION)filterDev->DeviceExtension;
    RtlZeroMemory(ext, sizeof(DEVICE_EXTENSION));

    status = IoAttachDeviceToDeviceStackSafe(filterDev, targetDev, &ext->LowerDevice);

    ObDereferenceObject(fileObj);   /* IoGetDeviceObjectPointer 참조 카운트 해제 */

    if (!NT_SUCCESS(status)) {
        DbgPrint("[KeyFilter] Attach 실패 (%ws): 0x%08X\n", DeviceNameStr, status);
        IoDeleteDevice(filterDev);
        return status;
    }

    /* 하위 디바이스 플래그 동기화 */
    filterDev->Flags |= DO_BUFFERED_IO | DO_POWER_PAGABLE;
    filterDev->Flags &= ~DO_DEVICE_INITIALIZING;

    DbgPrint("[KeyFilter] 성공적으로 attach: %ws\n", DeviceNameStr);
    return STATUS_SUCCESS;
}

/* ================================================================
 * DriverEntry — 개선된 버전
 * ================================================================ */
NTSTATUS DriverEntry(PDRIVER_OBJECT DriverObject, PUNICODE_STRING RegistryPath)
{
    NTSTATUS status;
    UNICODE_STRING devName, symlink;
    PDEVICE_OBJECT mainFilterDev = NULL;
    ULONG i;

    UNREFERENCED_PARAMETER(RegistryPath);

    /* 전역 스핀락 초기화 */
    KeInitializeSpinLock(&g_LogLock);

    RtlInitUnicodeString(&devName, DEVICE_NAME);
    RtlInitUnicodeString(&symlink, SYMLINK_NAME);

    /* 1. 유저 모드 접근용 메인 디바이스 생성 (IOCTL용, DeviceExtension 없음) */
    status = IoCreateDevice(DriverObject, 0, &devName, FILE_DEVICE_KEYBOARD, 0, FALSE, &mainFilterDev);
    if (!NT_SUCCESS(status)) {
        DbgPrint("[KeyFilter] 메인 디바이스 생성 실패: 0x%08X\n", status);
        return status;
    }

    status = IoCreateSymbolicLink(&symlink, &devName);
    if (!NT_SUCCESS(status)) {
        IoDeleteDevice(mainFilterDev);
        return status;
    }

    mainFilterDev->Flags |= DO_BUFFERED_IO;
    mainFilterDev->Flags &= ~DO_DEVICE_INITIALIZING;

    /* 2. 모든 KeyboardClass0 ~ KeyboardClass9 attach 시도 */
    for (i = 0; i < 10; i++) {
        WCHAR nameBuf[64];
        RtlStringCchPrintfW(nameBuf, RTL_NUMBER_OF(nameBuf), L"\\Device\\KeyboardClass%d", i);
        AttachToOneKeyboard(DriverObject, nameBuf);
    }

    /* 3. MajorFunction 등록 */
    for (i = 0; i <= IRP_MJ_MAXIMUM_FUNCTION; i++)
        DriverObject->MajorFunction[i] = DispatchPassThrough;

    DriverObject->MajorFunction[IRP_MJ_READ]           = DispatchRead;
    DriverObject->MajorFunction[IRP_MJ_DEVICE_CONTROL] = DispatchControl;
    DriverObject->DriverUnload                         = DriverUnload;

    DbgPrint("[KeyFilter] 로드 완료 — 물리 PC 지원 모드 (KeyboardClass0~9 모두 attach 시도)\n");
    DbgPrint("[KeyFilter] WinDbg: !devstack \\Device\\KeyboardClass0\n");

    return STATUS_SUCCESS;
}

/* ================================================================
 * DriverUnload — 여러 디바이스 정리
 * ================================================================ */
VOID DriverUnload(PDRIVER_OBJECT DriverObject)
{
    PDEVICE_OBJECT dev = DriverObject->DeviceObject;
    UNICODE_STRING symlink;

    RtlInitUnicodeString(&symlink, SYMLINK_NAME);
    IoDeleteSymbolicLink(&symlink);

    /* 모든 디바이스 객체 정리 */
    while (dev) {
        PDEVICE_OBJECT nextDev = dev->NextDevice;
        PDEVICE_EXTENSION ext = (PDEVICE_EXTENSION)dev->DeviceExtension;

        if (ext && ext->LowerDevice) {
            IoDetachDevice(ext->LowerDevice);
        }

        IoDeleteDevice(dev);
        dev = nextDev;
    }

    DbgPrint("[KeyFilter] 언로드 완료\n");
}
