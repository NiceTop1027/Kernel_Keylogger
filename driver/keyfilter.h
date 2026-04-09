/* keyfilter.h — 추천 개선 버전 (선택) */

#pragma once

#define IOCTL_KEYFILTER_READ \
    CTL_CODE(FILE_DEVICE_KEYBOARD, 0x800, METHOD_BUFFERED, FILE_ANY_ACCESS)

/* 개선된 KEY_RECORD (UnitId 추가) */
typedef struct _KEY_RECORD {
    LARGE_INTEGER Timestamp;   /* 시스템 시간 (100ns 단위) */
    USHORT        UnitId;      /* ← 추가: 키보드 번호 (KeyboardClassN의 N) */
    USHORT        MakeCode;    /* 스캔 코드 */
    USHORT        Flags;       /* 0 = Make(다운), 1 = Break(업) */
    USHORT        Reserved;    /* 나중에 확장용 */
} KEY_RECORD, *PKEY_RECORD;

#define LOG_CAPACITY 1025
