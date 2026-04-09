/*
 * keyfilter.h — 커널/유저 모드 공유 헤더
 *
 * 이 헤더는 드라이버(커널)와 리더(유저 모드) 양쪽에서 사용됩니다.
 * IOCTL 코드와 데이터 구조체를 동일하게 정의합니다.
 */

#pragma once

/* ── IOCTL 정의 ────────────────────────────────────────────────────────────────
 *
 * CTL_CODE(DeviceType, Function, Method, Access)
 *   DeviceType : FILE_DEVICE_KEYBOARD = 0x000B
 *   Function   : 0x800 (0x800~0xFFF = vendor 정의 범위)
 *   Method     : METHOD_BUFFERED = 0  (I/O 관리자가 버퍼 관리)
 *   Access     : FILE_ANY_ACCESS = 0
 *
 * 결과값: 0x000B2000  → \\.\KeyFilter 로 DeviceIoControl 호출 시 사용
 *   계산: (0xB<<16)|(0<<14)|(0x800<<2)|0 = 0x000B0000|0x00002000 = 0x000B2000
 */
#define IOCTL_KEYFILTER_READ \
    CTL_CODE(FILE_DEVICE_KEYBOARD, 0x800, METHOD_BUFFERED, FILE_ANY_ACCESS)

/* ── 키 레코드 구조체 ──────────────────────────────────────────────────────────
 *
 * KEYBOARD_INPUT_DATA (WDK 원본):
 *   USHORT UnitId;          // 키보드 번호 (보통 0)
 *   USHORT MakeCode;        // 하드웨어 스캔 코드
 *   USHORT Flags;           // KEY_MAKE(0)=다운, KEY_BREAK(1)=업
 *   USHORT Reserved;
 *   ULONG  ExtraInformation;
 *
 * 여기서는 필요한 필드만 저장합니다.
 */
typedef struct _KEY_RECORD {
    LARGE_INTEGER Timestamp;   /* GetSystemTime — 100ns 단위, Windows 에포크 */
    USHORT        MakeCode;    /* 하드웨어 스캔 코드 (Set 1 기준)             */
    USHORT        Flags;       /* 0 = 키다운, KEY_BREAK(1) = 키업            */
} KEY_RECORD, *PKEY_RECORD;

#define LOG_CAPACITY 1025      /* 링 버퍼 슬롯 수 — 1개 슬롯이 빈 상태 유지용으로 낭비되므로
                                 * 실제 최대 저장량 = 1025 - 1 = 1024 개              */
