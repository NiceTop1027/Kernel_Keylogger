/*
 * keyfilter.h — 커널/유저 모드 공유 헤더
 *
 * 실제 키보드 스택 후킹은 하지 않습니다.
 * 유저 모드 GUI/콘솔 데모가 현재 앱 창에서 읽은 이벤트만 드라이버에 제출하고,
 * 드라이버는 그 이벤트를 커널 링 버퍼에 저장합니다.
 */

#pragma once

#define IOCTL_KEYFILTER_READ \
    CTL_CODE(FILE_DEVICE_UNKNOWN, 0x800, METHOD_BUFFERED, FILE_READ_DATA)

#define IOCTL_KEYFILTER_SUBMIT \
    CTL_CODE(FILE_DEVICE_UNKNOWN, 0x801, METHOD_BUFFERED, FILE_WRITE_DATA)

#define IOCTL_KEYFILTER_RESET \
    CTL_CODE(FILE_DEVICE_UNKNOWN, 0x802, METHOD_BUFFERED, FILE_WRITE_DATA)

#define IOCTL_KEYFILTER_STATUS \
    CTL_CODE(FILE_DEVICE_UNKNOWN, 0x803, METHOD_BUFFERED, FILE_READ_DATA)

#define KEY_FLAG_BREAK         0x0001
#define KEY_FLAG_EXTENDED      0x0002
#define KEY_FLAG_SYNTHETIC     0x0100
#define KEY_FLAG_CONSOLE_SCOPE 0x0200
#define KEY_FLAG_GUI_SCOPE     0x0400

#define KEYFILTER_STATUS_READY 0x00000001

#define KEY_TEXT_LEN 16
#define LOG_CAPACITY 1025

#pragma pack(push, 1)
typedef struct _KEY_RECORD {
    ULONGLONG Timestamp100ns;
    USHORT    MakeCode;
    USHORT    Flags;
    USHORT    TextUtf16[KEY_TEXT_LEN];
} KEY_RECORD, *PKEY_RECORD;

typedef struct _KEYFILTER_STATUS {
    ULONG QueuedCount;
    ULONG Capacity;
    ULONG Flags;
} KEYFILTER_STATUS, *PKEYFILTER_STATUS;
#pragma pack(pop)
