"""
reader.py — 콘솔 범위 입력 데모
=================================

현재 콘솔 창에서만 입력을 읽고, 그 이벤트를 KeyFilter.sys 에 제출합니다.
드라이버는 커널 링 버퍼에 이벤트를 저장하고, 이 스크립트는 다시 그 값을 읽어
화면 출력, SQLite 저장, 텍스트 파일 저장을 수행합니다.
"""

from __future__ import annotations

import argparse
import ctypes
import ctypes.wintypes
import io
import os
import struct
import sys
from datetime import datetime, timedelta, timezone

import store

sys.stdout = io.TextIOWrapper(
    sys.stdout.buffer, encoding="utf-8", errors="replace", line_buffering=True
)
sys.stderr = io.TextIOWrapper(
    sys.stderr.buffer, encoding="utf-8", errors="replace"
)

_k32 = ctypes.windll.kernel32

FILE_DEVICE_UNKNOWN = 0x00000022
METHOD_BUFFERED = 0
FILE_READ_DATA = 0x0001
FILE_WRITE_DATA = 0x0002

GENERIC_READ = 0x80000000
GENERIC_WRITE = 0x40000000
OPEN_EXISTING = 3
INVALID_HANDLE = ctypes.wintypes.HANDLE(-1).value

STD_INPUT_HANDLE = -10
KEY_EVENT = 0x0001
ENABLE_EXTENDED_FLAGS = 0x0080
ENABLE_QUICK_EDIT_MODE = 0x0040
ENHANCED_KEY = 0x0100
VK_ESCAPE = 0x1B

KEY_FLAG_BREAK = 0x0001
KEY_FLAG_EXTENDED = 0x0002
KEY_TEXT_LEN = 16
RECORDS_PER_READ = 64
WINDOWS_EPOCH_DIFF_SEC = 11644473600


def ctl_code(device_type: int, function: int, method: int, access: int) -> int:
    return (device_type << 16) | (access << 14) | (function << 2) | method


IOCTL_KEYFILTER_READ = ctl_code(
    FILE_DEVICE_UNKNOWN, 0x800, METHOD_BUFFERED, FILE_READ_DATA
)
IOCTL_KEYFILTER_SUBMIT = ctl_code(
    FILE_DEVICE_UNKNOWN, 0x801, METHOD_BUFFERED, FILE_WRITE_DATA
)
IOCTL_KEYFILTER_RESET = ctl_code(
    FILE_DEVICE_UNKNOWN, 0x802, METHOD_BUFFERED, FILE_WRITE_DATA
)


class CHAR_UNION(ctypes.Union):
    _fields_ = [
        ("UnicodeChar", ctypes.wintypes.WCHAR),
        ("AsciiChar", ctypes.c_char),
    ]


class KEY_EVENT_RECORD(ctypes.Structure):
    _fields_ = [
        ("bKeyDown", ctypes.wintypes.BOOL),
        ("wRepeatCount", ctypes.wintypes.WORD),
        ("wVirtualKeyCode", ctypes.wintypes.WORD),
        ("wVirtualScanCode", ctypes.wintypes.WORD),
        ("uChar", CHAR_UNION),
        ("dwControlKeyState", ctypes.wintypes.DWORD),
    ]


class EVENT_UNION(ctypes.Union):
    _fields_ = [
        ("KeyEvent", KEY_EVENT_RECORD),
        ("Padding", ctypes.c_ubyte * 16),
    ]


class INPUT_RECORD(ctypes.Structure):
    _fields_ = [
        ("EventType", ctypes.wintypes.WORD),
        ("Event", EVENT_UNION),
    ]


class KEY_RECORD(ctypes.Structure):
    _pack_ = 1
    _fields_ = [
        ("Timestamp100ns", ctypes.c_ulonglong),
        ("MakeCode", ctypes.c_ushort),
        ("Flags", ctypes.c_ushort),
        ("TextUtf16", ctypes.c_ushort * KEY_TEXT_LEN),
    ]


_k32.CreateFileW.argtypes = [
    ctypes.wintypes.LPCWSTR,
    ctypes.wintypes.DWORD,
    ctypes.wintypes.DWORD,
    ctypes.wintypes.LPVOID,
    ctypes.wintypes.DWORD,
    ctypes.wintypes.DWORD,
    ctypes.wintypes.HANDLE,
]
_k32.CreateFileW.restype = ctypes.wintypes.HANDLE
_k32.CloseHandle.argtypes = [ctypes.wintypes.HANDLE]
_k32.CloseHandle.restype = ctypes.wintypes.BOOL
_k32.DeviceIoControl.argtypes = [
    ctypes.wintypes.HANDLE,
    ctypes.wintypes.DWORD,
    ctypes.wintypes.LPVOID,
    ctypes.wintypes.DWORD,
    ctypes.wintypes.LPVOID,
    ctypes.wintypes.DWORD,
    ctypes.POINTER(ctypes.wintypes.DWORD),
    ctypes.wintypes.LPVOID,
]
_k32.DeviceIoControl.restype = ctypes.wintypes.BOOL
_k32.GetStdHandle.argtypes = [ctypes.wintypes.DWORD]
_k32.GetStdHandle.restype = ctypes.wintypes.HANDLE
_k32.GetConsoleMode.argtypes = [
    ctypes.wintypes.HANDLE,
    ctypes.POINTER(ctypes.wintypes.DWORD),
]
_k32.GetConsoleMode.restype = ctypes.wintypes.BOOL
_k32.SetConsoleMode.argtypes = [ctypes.wintypes.HANDLE, ctypes.wintypes.DWORD]
_k32.SetConsoleMode.restype = ctypes.wintypes.BOOL
_k32.FlushConsoleInputBuffer.argtypes = [ctypes.wintypes.HANDLE]
_k32.FlushConsoleInputBuffer.restype = ctypes.wintypes.BOOL
_k32.ReadConsoleInputW.argtypes = [
    ctypes.wintypes.HANDLE,
    ctypes.POINTER(INPUT_RECORD),
    ctypes.wintypes.DWORD,
    ctypes.POINTER(ctypes.wintypes.DWORD),
]
_k32.ReadConsoleInputW.restype = ctypes.wintypes.BOOL
_k32.GetLastError.restype = ctypes.wintypes.DWORD


SPECIAL_VK: dict[int, str] = {
    0x08: "[Backspace]",
    0x09: "[Tab]",
    0x0D: "[Enter]",
    0x20: " ",
    0x21: "[PgUp]",
    0x22: "[PgDn]",
    0x23: "[End]",
    0x24: "[Home]",
    0x25: "[Left]",
    0x26: "[Up]",
    0x27: "[Right]",
    0x28: "[Down]",
    0x2D: "[Ins]",
    0x2E: "[Del]",
    0x70: "[F1]",
    0x71: "[F2]",
    0x72: "[F3]",
    0x73: "[F4]",
    0x74: "[F5]",
    0x75: "[F6]",
    0x76: "[F7]",
    0x77: "[F8]",
    0x78: "[F9]",
    0x79: "[F10]",
    0x7A: "[F11]",
    0x7B: "[F12]",
    0x1B: "[Esc]",
}

RESET = "\033[0m"
GRAY = "\033[90m"
GREEN = "\033[92m"
YELLOW = "\033[93m"


def utf16_units_from_text(text: str) -> ctypes.Array:
    buf = (ctypes.c_ushort * KEY_TEXT_LEN)()
    encoded = text.encode("utf-16le")[: KEY_TEXT_LEN * 2]
    units = struct.unpack(f"<{len(encoded) // 2}H", encoded) if encoded else ()
    for index, unit in enumerate(units):
        buf[index] = unit
    return buf


def text_from_record(record: KEY_RECORD) -> str:
    chars: list[str] = []
    for unit in record.TextUtf16:
        if unit == 0:
            break
        chars.append(chr(unit))
    return "".join(chars)


def filetime_to_datetime(ts_100ns: int) -> datetime:
    unix_sec = (ts_100ns / 1e7) - WINDOWS_EPOCH_DIFF_SEC
    kst = timezone(timedelta(hours=9))
    return datetime.fromtimestamp(unix_sec, tz=kst)


def visible_text_from_key_event(key_event: KEY_EVENT_RECORD) -> str:
    ch = key_event.uChar.UnicodeChar
    if ch:
        if ch == "\r":
            return "[Enter]"
        if ch == "\t":
            return "[Tab]"
        if ch == "\b":
            return "[Backspace]"
        if ord(ch) < 0x20:
            return f"[Ctrl+{chr(ord(ch) + 0x40)}]"
        return ch
    return SPECIAL_VK.get(key_event.wVirtualKeyCode, f"[VK:0x{key_event.wVirtualKeyCode:02X}]")


def format_line(ts_str: str, key_str: str) -> str:
    color = YELLOW if key_str.startswith("[") or key_str.startswith("↑") else GREEN
    return f"{GRAY}{ts_str}{RESET}  {color}{key_str}{RESET}"


def print_notice(auto_accept: bool) -> None:
    notice = (
        "이 프로그램은 현재 콘솔 창에서만 입력을 읽는 안전한 데모입니다.\n"
        "시스템 전역 입력, 백그라운드 앱 입력, 자격 증명 수집은 하지 않습니다.\n"
        "윤리적 책임과 무단 복제/무단 수집 금지 원칙을 확인한 뒤에만 사용하십시오.\n"
    )
    print(notice)
    if auto_accept:
        return

    answer = input("계속하려면 YES 를 입력하세요: ").strip().upper()
    if answer != "YES":
        raise SystemExit("동의하지 않아 종료합니다.")


class ConsoleInput:
    def __init__(self) -> None:
        self._handle: int | None = None
        self._original_mode = ctypes.wintypes.DWORD(0)

    def open(self) -> None:
        handle = _k32.GetStdHandle(STD_INPUT_HANDLE)
        if handle in (0, INVALID_HANDLE):
            raise OSError("콘솔 입력 핸들을 열 수 없습니다.")

        if not _k32.GetConsoleMode(handle, ctypes.byref(self._original_mode)):
            raise OSError("콘솔 모드를 읽을 수 없습니다.")

        new_mode = (self._original_mode.value | ENABLE_EXTENDED_FLAGS) & ~ENABLE_QUICK_EDIT_MODE
        if not _k32.SetConsoleMode(handle, new_mode):
            raise OSError("콘솔 모드를 설정할 수 없습니다.")

        _k32.FlushConsoleInputBuffer(handle)
        self._handle = handle

    def close(self) -> None:
        if self._handle is not None:
            _k32.SetConsoleMode(self._handle, self._original_mode.value)
            self._handle = None

    def read_key_event(self) -> KEY_EVENT_RECORD:
        if self._handle is None:
            raise RuntimeError("콘솔이 열리지 않았습니다.")

        record = INPUT_RECORD()
        read = ctypes.wintypes.DWORD(0)

        while True:
            ok = _k32.ReadConsoleInputW(
                self._handle, ctypes.byref(record), 1, ctypes.byref(read)
            )
            if not ok:
                raise OSError(f"ReadConsoleInputW 실패 (오류: {_k32.GetLastError()})")

            if record.EventType == KEY_EVENT:
                return record.Event.KeyEvent

    def __enter__(self) -> "ConsoleInput":
        self.open()
        return self

    def __exit__(self, *_: object) -> None:
        self.close()


class KeyFilterClient:
    def __init__(self) -> None:
        self._handle: int | None = None

    def open(self) -> None:
        handle = _k32.CreateFileW(
            r"\\.\KeyFilter",
            GENERIC_READ | GENERIC_WRITE,
            0,
            None,
            OPEN_EXISTING,
            0,
            None,
        )
        if handle == INVALID_HANDLE:
            err = _k32.GetLastError()
            raise OSError(
                f"드라이버 열기 실패 (오류: {err})\n"
                "  sc query KeyFilter 로 로드 여부를 확인하세요.\n"
                "  관리자 권한으로 실행했는지 확인하세요."
            )
        self._handle = handle

    def close(self) -> None:
        if self._handle is not None:
            _k32.CloseHandle(self._handle)
            self._handle = None

    def reset(self) -> None:
        if self._handle is None:
            return
        returned = ctypes.wintypes.DWORD(0)
        ok = _k32.DeviceIoControl(
            self._handle,
            IOCTL_KEYFILTER_RESET,
            None,
            0,
            None,
            0,
            ctypes.byref(returned),
            None,
        )
        if not ok:
            raise OSError(f"버퍼 초기화 실패 (오류: {_k32.GetLastError()})")

    def submit(self, record: KEY_RECORD) -> None:
        if self._handle is None:
            return
        returned = ctypes.wintypes.DWORD(0)
        ok = _k32.DeviceIoControl(
            self._handle,
            IOCTL_KEYFILTER_SUBMIT,
            ctypes.byref(record),
            ctypes.sizeof(record),
            None,
            0,
            ctypes.byref(returned),
            None,
        )
        if not ok:
            raise OSError(f"이벤트 제출 실패 (오류: {_k32.GetLastError()})")

    def read_records(self) -> list[KEY_RECORD]:
        if self._handle is None:
            return []

        array_type = KEY_RECORD * RECORDS_PER_READ
        buf = array_type()
        returned = ctypes.wintypes.DWORD(0)
        ok = _k32.DeviceIoControl(
            self._handle,
            IOCTL_KEYFILTER_READ,
            None,
            0,
            buf,
            ctypes.sizeof(buf),
            ctypes.byref(returned),
            None,
        )
        if not ok:
            raise OSError(f"드라이버 읽기 실패 (오류: {_k32.GetLastError()})")

        count = returned.value // ctypes.sizeof(KEY_RECORD)
        return list(buf[:count])

    def __enter__(self) -> "KeyFilterClient":
        self.open()
        return self

    def __exit__(self, *_: object) -> None:
        self.close()


def build_record(key_event: KEY_EVENT_RECORD, text: str, is_break: bool) -> KEY_RECORD:
    record = KEY_RECORD()
    units = utf16_units_from_text(text)
    record.MakeCode = key_event.wVirtualScanCode
    record.Flags = KEY_FLAG_BREAK if is_break else 0
    if key_event.dwControlKeyState & ENHANCED_KEY:
        record.Flags |= KEY_FLAG_EXTENDED
    for index, unit in enumerate(units):
        record.TextUtf16[index] = unit
    return record


def drain_driver(
    driver: KeyFilterClient,
    db,
    log_file,
) -> None:
    for record in driver.read_records():
        key_str = text_from_record(record)
        if not key_str:
            continue

        dt = filetime_to_datetime(record.Timestamp100ns)
        ts_str = dt.strftime("%H:%M:%S.%f")[:-3]
        ts_ms = int(dt.timestamp() * 1000)

        store.insert(db, key_str, ts_ms)
        print(format_line(ts_str, key_str))
        log_file.write(f"{ts_str}  {key_str}\n")
        log_file.flush()


def main() -> None:
    default_log = os.path.abspath(
        os.path.join(os.path.dirname(__file__), "..", "captured_keys.txt")
    )

    parser = argparse.ArgumentParser(description="콘솔 범위 커널 입력 데모")
    parser.add_argument(
        "--log",
        metavar="FILE",
        default=default_log,
        help="텍스트 로그 파일 경로 (기본: captured_keys.txt)",
    )
    parser.add_argument(
        "--show-up", action="store_true", help="키 업 이벤트도 표시"
    )
    parser.add_argument(
        "--accept", action="store_true", help="윤리 고지에 자동 동의"
    )
    args = parser.parse_args()

    print_notice(args.accept)

    db = store.get_conn()
    store.init(db)

    print("KeyFilter 콘솔 데모")
    print(f"DB 저장   : {store.DB_PATH}")
    print(f"TXT 저장  : {args.log}")
    print("입력 범위 : 현재 콘솔 창만")
    print("종료 키   : Esc")
    print("─" * 55)

    try:
        with open(args.log, "a", encoding="utf-8") as log_file:
            with KeyFilterClient() as driver, ConsoleInput() as console:
                driver.reset()

                while True:
                    key_event = console.read_key_event()
                    repeat_count = max(1, int(key_event.wRepeatCount))
                    base_text = visible_text_from_key_event(key_event)
                    if not base_text:
                        continue

                    is_break = not bool(key_event.bKeyDown)
                    if is_break and not args.show_up:
                        continue

                    text = f"↑{base_text}" if is_break else base_text
                    loop_count = 1 if is_break else repeat_count

                    for _ in range(loop_count):
                        driver.submit(build_record(key_event, text, is_break))
                        drain_driver(driver, db, log_file)

                    if key_event.bKeyDown and key_event.wVirtualKeyCode == VK_ESCAPE:
                        print("\n[종료] Esc 입력")
                        return

    except KeyboardInterrupt:
        print("\n[종료] Ctrl+C")
    except OSError as exc:
        print(f"\n[오류] {exc}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
