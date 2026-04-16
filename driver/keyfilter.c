/*
 * keyfilter.c — 안전한 커널 입력 데모 드라이버
 *
 * 이 드라이버는 키보드 클래스 스택에 붙지 않습니다.
 * 유저 모드 데모가 현재 앱 창에서 읽은 입력 이벤트를 IOCTL 로 제출하면,
 * 드라이버가 커널 링 버퍼에 적재하고 상태/로그를 다시 읽어 갈 수 있게 해 줍니다.
 */

#include <ntddk.h>
#include <wdm.h>
#include "keyfilter.h"

#define DEVICE_NAME  L"\\Device\\KeyFilter"
#define SYMLINK_NAME L"\\DosDevices\\KeyFilter"

typedef struct _DEVICE_EXTENSION {
    KEY_RECORD LogBuffer[LOG_CAPACITY];
    ULONG      LogHead;
    ULONG      LogTail;
    KSPIN_LOCK LogLock;
} DEVICE_EXTENSION, *PDEVICE_EXTENSION;

DRIVER_UNLOAD   DriverUnload;
DRIVER_DISPATCH DispatchCreateClose;
DRIVER_DISPATCH DispatchControl;
DRIVER_DISPATCH DispatchUnsupported;

static VOID
CompleteRequest(
    _In_ PIRP Irp,
    _In_ NTSTATUS Status,
    _In_ ULONG_PTR Information)
{
    Irp->IoStatus.Status = Status;
    Irp->IoStatus.Information = Information;
    IoCompleteRequest(Irp, IO_NO_INCREMENT);
}

static VOID
PushRecordLocked(
    _Inout_ PDEVICE_EXTENSION Ext,
    _In_ const PKEY_RECORD Record)
{
    ULONG nextTail;

    Ext->LogBuffer[Ext->LogTail] = *Record;
    nextTail = (Ext->LogTail + 1) % LOG_CAPACITY;

    if (nextTail == Ext->LogHead)
        Ext->LogHead = (Ext->LogHead + 1) % LOG_CAPACITY;

    Ext->LogTail = nextTail;
}

static ULONG
GetQueuedCountLocked(_In_ const PDEVICE_EXTENSION Ext)
{
    if (Ext->LogTail >= Ext->LogHead)
        return Ext->LogTail - Ext->LogHead;

    return LOG_CAPACITY - (Ext->LogHead - Ext->LogTail);
}

static VOID
ResetBufferLocked(_Inout_ PDEVICE_EXTENSION Ext)
{
    Ext->LogHead = 0;
    Ext->LogTail = 0;
    RtlZeroMemory(Ext->LogBuffer, sizeof(Ext->LogBuffer));
}

static VOID
QueueSubmittedRecords(
    _Inout_ PDEVICE_EXTENSION Ext,
    _In_reads_(Count) const PKEY_RECORD Input,
    _In_ ULONG Count)
{
    KIRQL oldIrql;
    ULONG i;

    KeAcquireSpinLock(&Ext->LogLock, &oldIrql);

    for (i = 0; i < Count; i++) {
        KEY_RECORD record;
        LARGE_INTEGER now;

        RtlZeroMemory(&record, sizeof(record));
        record.MakeCode = Input[i].MakeCode;
        record.Flags = (USHORT)(Input[i].Flags | KEY_FLAG_SYNTHETIC);
        RtlCopyMemory(record.TextUtf16, Input[i].TextUtf16, sizeof(record.TextUtf16));
        record.TextUtf16[KEY_TEXT_LEN - 1] = 0;

        KeQuerySystemTime(&now);
        record.Timestamp100ns = (ULONGLONG)now.QuadPart;

        PushRecordLocked(Ext, &record);
    }

    KeReleaseSpinLock(&Ext->LogLock, oldIrql);
}

NTSTATUS
DispatchUnsupported(
    _In_ PDEVICE_OBJECT DeviceObject,
    _In_ PIRP Irp)
{
    UNREFERENCED_PARAMETER(DeviceObject);
    CompleteRequest(Irp, STATUS_INVALID_DEVICE_REQUEST, 0);
    return STATUS_INVALID_DEVICE_REQUEST;
}

NTSTATUS
DispatchCreateClose(
    _In_ PDEVICE_OBJECT DeviceObject,
    _In_ PIRP Irp)
{
    UNREFERENCED_PARAMETER(DeviceObject);
    CompleteRequest(Irp, STATUS_SUCCESS, 0);
    return STATUS_SUCCESS;
}

NTSTATUS
DispatchControl(
    _In_ PDEVICE_OBJECT DeviceObject,
    _In_ PIRP Irp)
{
    PDEVICE_EXTENSION  ext;
    PIO_STACK_LOCATION stack;
    ULONG inLen;
    ULONG outLen;
    NTSTATUS status;
    ULONG_PTR info;

    ext = (PDEVICE_EXTENSION)DeviceObject->DeviceExtension;
    stack = IoGetCurrentIrpStackLocation(Irp);
    inLen = stack->Parameters.DeviceIoControl.InputBufferLength;
    outLen = stack->Parameters.DeviceIoControl.OutputBufferLength;
    status = STATUS_SUCCESS;
    info = 0;

    switch (stack->Parameters.DeviceIoControl.IoControlCode) {
    case IOCTL_KEYFILTER_READ:
    {
        PKEY_RECORD outBuf;
        ULONG capacity;
        ULONG copied;
        KIRQL oldIrql;

        outBuf = (PKEY_RECORD)Irp->AssociatedIrp.SystemBuffer;
        capacity = outLen / sizeof(KEY_RECORD);
        copied = 0;

        KeAcquireSpinLock(&ext->LogLock, &oldIrql);

        while (copied < capacity && ext->LogHead != ext->LogTail) {
            outBuf[copied] = ext->LogBuffer[ext->LogHead];
            ext->LogHead = (ext->LogHead + 1) % LOG_CAPACITY;
            copied++;
        }

        KeReleaseSpinLock(&ext->LogLock, oldIrql);
        info = (ULONG_PTR)(copied * sizeof(KEY_RECORD));
        break;
    }

    case IOCTL_KEYFILTER_SUBMIT:
    {
        PKEY_RECORD inBuf;
        ULONG count;

        if (inLen == 0 || (inLen % sizeof(KEY_RECORD)) != 0) {
            status = STATUS_INVALID_BUFFER_SIZE;
            break;
        }

        inBuf = (PKEY_RECORD)Irp->AssociatedIrp.SystemBuffer;
        count = inLen / sizeof(KEY_RECORD);
        QueueSubmittedRecords(ext, inBuf, count);
        info = inLen;
        break;
    }

    case IOCTL_KEYFILTER_RESET:
    {
        KIRQL oldIrql;

        KeAcquireSpinLock(&ext->LogLock, &oldIrql);
        ResetBufferLocked(ext);
        KeReleaseSpinLock(&ext->LogLock, oldIrql);
        break;
    }

    case IOCTL_KEYFILTER_STATUS:
    {
        PKEYFILTER_STATUS outStatus;
        KIRQL oldIrql;

        if (outLen < sizeof(KEYFILTER_STATUS)) {
            status = STATUS_BUFFER_TOO_SMALL;
            break;
        }

        outStatus = (PKEYFILTER_STATUS)Irp->AssociatedIrp.SystemBuffer;

        KeAcquireSpinLock(&ext->LogLock, &oldIrql);
        outStatus->QueuedCount = GetQueuedCountLocked(ext);
        outStatus->Capacity = LOG_CAPACITY - 1;
        outStatus->Flags = KEYFILTER_STATUS_READY;
        KeReleaseSpinLock(&ext->LogLock, oldIrql);

        info = sizeof(KEYFILTER_STATUS);
        break;
    }

    default:
        status = STATUS_INVALID_DEVICE_REQUEST;
        break;
    }

    CompleteRequest(Irp, status, info);
    return status;
}

VOID
DriverUnload(_In_ PDRIVER_OBJECT DriverObject)
{
    UNICODE_STRING symlink;

    RtlInitUnicodeString(&symlink, SYMLINK_NAME);
    IoDeleteSymbolicLink(&symlink);

    if (DriverObject->DeviceObject != NULL)
        IoDeleteDevice(DriverObject->DeviceObject);
}

NTSTATUS
DriverEntry(
    _In_ PDRIVER_OBJECT DriverObject,
    _In_ PUNICODE_STRING RegistryPath)
{
    UNICODE_STRING devName;
    UNICODE_STRING symlink;
    PDEVICE_OBJECT deviceObject;
    PDEVICE_EXTENSION ext;
    NTSTATUS status;
    ULONG i;

    UNREFERENCED_PARAMETER(RegistryPath);

    RtlInitUnicodeString(&devName, DEVICE_NAME);
    RtlInitUnicodeString(&symlink, SYMLINK_NAME);

    status = IoCreateDevice(
        DriverObject,
        sizeof(DEVICE_EXTENSION),
        &devName,
        FILE_DEVICE_UNKNOWN,
        0,
        FALSE,
        &deviceObject
    );
    if (!NT_SUCCESS(status))
        return status;

    status = IoCreateSymbolicLink(&symlink, &devName);
    if (!NT_SUCCESS(status)) {
        IoDeleteDevice(deviceObject);
        return status;
    }

    ext = (PDEVICE_EXTENSION)deviceObject->DeviceExtension;
    RtlZeroMemory(ext, sizeof(*ext));
    KeInitializeSpinLock(&ext->LogLock);

    for (i = 0; i <= IRP_MJ_MAXIMUM_FUNCTION; i++)
        DriverObject->MajorFunction[i] = DispatchUnsupported;

    DriverObject->MajorFunction[IRP_MJ_CREATE] = DispatchCreateClose;
    DriverObject->MajorFunction[IRP_MJ_CLOSE] = DispatchCreateClose;
    DriverObject->MajorFunction[IRP_MJ_CLEANUP] = DispatchCreateClose;
    DriverObject->MajorFunction[IRP_MJ_DEVICE_CONTROL] = DispatchControl;
    DriverObject->DriverUnload = DriverUnload;

    deviceObject->Flags |= DO_BUFFERED_IO;
    deviceObject->Flags &= ~DO_DEVICE_INITIALIZING;

    DbgPrint("[KeyFilter] Safe driver loaded.\n");
    return STATUS_SUCCESS;
}
