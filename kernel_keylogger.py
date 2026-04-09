"""
kernel_keylogger.py — CMD 조회 도구
=====================================

CMD 에서 바로 실행:
    kernel_keylogger            # 전체 로그 출력
    kernel_keylogger --tail 50  # 최근 50개
    kernel_keylogger --find 바보  # 특정 키 검색
    kernel_keylogger --stats    # 통계만
"""

from __future__ import annotations

import argparse
import sys
import os
from datetime import datetime

# reader/ 폴더의 store 모듈 참조
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "reader"))
import store

# 컬러
RESET  = "\033[0m"
BOLD   = "\033[1m"
GRAY   = "\033[90m"
GREEN  = "\033[92m"
YELLOW = "\033[93m"
RED    = "\033[91m"
CYAN   = "\033[96m"


def print_header() -> None:
    print(f"\n{BOLD}{'─'*60}{RESET}")
    print(f"{BOLD}  KeyLogger DB 조회{RESET}")
    print(f"  DB: {store.DB_PATH}")
    print(f"{'─'*60}{RESET}\n")


def is_special(key: str) -> bool:
    return key.startswith("[")


def colorize(key: str) -> str:
    return f"{YELLOW}{key}{RESET}" if is_special(key) else f"{GREEN}{key}{RESET}"


def print_rows(rows: list, find: str = "") -> None:
    if not rows:
        print(f"  {GRAY}(저장된 데이터 없음){RESET}\n")
        return

    # 헤더
    print(f"  {GRAY}{'#':<6} {'시각':<22} {'키':<18}{RESET}")
    print(f"  {GRAY}{'─'*50}{RESET}")

    for i, row in enumerate(rows, 1):
        dt  = row["datetime"]
        key = row["key"]

        # 검색어 하이라이트
        if find and find in key:
            key_display = f"{RED}{key}{RESET}"
            prefix = f"{RED}⚠ {RESET}"
        else:
            key_display = colorize(key)
            prefix = "  "

        print(f"  {GRAY}{i:<6}{RESET}{prefix}{GRAY}{dt:<22}{RESET}{key_display}")

    print()


def print_stats(conn) -> None:
    total = store.count(conn)

    # 오늘 통계
    today = datetime.now().strftime("%Y-%m-%d")
    today_rows = conn.execute(
        "SELECT COUNT(*) FROM keystrokes WHERE datetime LIKE ?", (f"{today}%",)
    ).fetchone()[0]

    # 가장 많이 누른 키 TOP 5
    top = conn.execute(
        "SELECT key, COUNT(*) as cnt FROM keystrokes GROUP BY key ORDER BY cnt DESC LIMIT 5"
    ).fetchall()

    # 첫 / 마지막 기록
    first = conn.execute("SELECT datetime FROM keystrokes ORDER BY ts ASC  LIMIT 1").fetchone()
    last  = conn.execute("SELECT datetime FROM keystrokes ORDER BY ts DESC LIMIT 1").fetchone()

    print(f"  {CYAN}총 키스트로크{RESET}   : {BOLD}{total:,}{RESET}")
    print(f"  {CYAN}오늘 키스트로크{RESET} : {BOLD}{today_rows:,}{RESET}")
    print(f"  {CYAN}첫 기록{RESET}         : {first[0] if first else '-'}")
    print(f"  {CYAN}마지막 기록{RESET}     : {last[0]  if last  else '-'}")
    print()

    if top:
        print(f"  {BOLD}TOP 5 키{RESET}")
        for key, cnt in top:
            bar = "█" * min(cnt, 30)
            print(f"    {colorize(key):<30} {GRAY}{cnt:>5}회  {bar}{RESET}")
    print()


def main() -> None:
    parser = argparse.ArgumentParser(
        prog="kernel_keylogger",
        description="KeyLogger DB 조회 도구"
    )
    parser.add_argument("--tail",  metavar="N",    type=int, help="최근 N개만 표시")
    parser.add_argument("--find",  metavar="KEY",  type=str, help="특정 키 검색")
    parser.add_argument("--stats", action="store_true",      help="통계만 표시")
    parser.add_argument("--all",   action="store_true",      help="전체 출력 (기본: 최근 200개)")
    args = parser.parse_args()

    # DB 연결
    try:
        conn = store.get_conn()
        store.init(conn)
    except Exception as e:
        print(f"{RED}[오류] DB 연결 실패: {e}{RESET}", file=sys.stderr)
        sys.exit(1)

    print_header()

    if args.stats:
        print_stats(conn)
        return

    # 데이터 조회
    if args.find:
        rows = conn.execute(
            "SELECT * FROM keystrokes WHERE key LIKE ? ORDER BY ts",
            (f"%{args.find}%",)
        ).fetchall()
        print(f"  검색: {RED}'{args.find}'{RESET}  →  {len(rows)}건\n")
    elif args.tail:
        rows = store.fetch_all(conn, limit=args.tail)   # 이미 ASC 정렬
        print(f"  최근 {args.tail}개\n")
    elif args.all:
        rows = store.fetch_all(conn)
        print(f"  전체 {len(rows):,}개\n")
    else:
        # 기본: 최근 200개
        rows = store.fetch_all(conn, limit=200)   # 이미 ASC 정렬
        total = store.count(conn)
        print(f"  최근 {len(rows)}개 / 전체 {total:,}개  (전체 보기: --all)\n")

    print_stats(conn)
    print_rows(rows, find=args.find or "")


if __name__ == "__main__":
    main()
