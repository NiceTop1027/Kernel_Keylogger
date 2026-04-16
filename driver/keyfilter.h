/*
 * keyfilter.h — 커널/유저 모드 공유 헤더
 *
 * 이 버전은 실제 키보드 스택을 가로채지 않습니다.
 * 현재 콘솔에서 사용자가 직접 입력한 이벤트만 유저 모드가 드라이버에 전달하고,
 * 드라이버는 그 이벤트를 커널 링 버퍼에 저장합니다.
 */

#pragma once

#define IOCTL_KEYFILTER_READ \
    CTL_CODE(FILE_DEVICE_UNKNOWN, 0x800, METHOD_BUFFERED, FILE_READ_DATA)

#define IOCTL_KEYFILTER_SUBMIT \
    CTL_CODE(FILE_DEVICE_UNKNOWN, 0x801, METHOD_BUFFERED, FILE_WRITE_DATA)

#define IOCTL_KEYFILTER_RESET \
    CTL_CODE(FILE_DEVICE_UNKNOWN, 0x802, METHOD_BUFFERED, FILE_WRITE_DATA)

#define KEY_FLAG_BREAK         0x0001
#define KEY_FLAG_EXTENDED      0x0002
#define KEY_FLAG_SYNTHETIC     0x0100
#define KEY_FLAG_CONSOLE_SCOPE 0x0200

#define KEY_TEXT_LEN 16
#define LOG_CAPACITY 1025

#pragma pack(push, 1)
typedef struct _KEY_RECORD {
    ULONGLONG Timestamp100ns;       /* 드라이버가 저장 시각을 채움 */
    USHORT    MakeCode;             /* 콘솔이 보고한 스캔 코드     */
    USHORT    Flags;                /* KEY_FLAG_* 조합             */
    USHORT    TextUtf16[KEY_TEXT_LEN];
} KEY_RECORD, *PKEY_RECORD;
#pragma pack(pop)
