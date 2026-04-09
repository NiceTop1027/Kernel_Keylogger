"""
store.py — 키스트로크 SQLite 영구 저장소
reader.py 와 kernel_keylogger.py 가 공유합니다.
"""

import sqlite3
import os
from datetime import datetime

DB_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "keylog.db")


def get_conn() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    return conn


def init(conn: sqlite3.Connection) -> None:
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS keystrokes (
            id        INTEGER PRIMARY KEY AUTOINCREMENT,
            key       TEXT    NOT NULL,
            ts        INTEGER NOT NULL,
            datetime  TEXT    NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_ts ON keystrokes(ts DESC);
    """)
    conn.commit()


def insert(conn: sqlite3.Connection, key: str, ts_ms: int) -> None:
    dt = datetime.fromtimestamp(ts_ms / 1000).strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]
    conn.execute(
        "INSERT INTO keystrokes (key, ts, datetime) VALUES (?, ?, ?)",
        (key, ts_ms, dt)
    )
    conn.commit()


def fetch_all(conn: sqlite3.Connection, limit: int = 0) -> list:
    """
    항상 오름차순(시간순)으로 반환.
    limit > 0 이면 최신 N개를 시간순으로 반환.
    """
    if limit:
        # DESC+LIMIT 으로 최신 N개 가져온 뒤 서브쿼리로 ASC 정렬
        return conn.execute(
            "SELECT * FROM (SELECT * FROM keystrokes ORDER BY ts DESC LIMIT ?) "
            "ORDER BY ts ASC",
            (limit,)
        ).fetchall()
    return conn.execute(
        "SELECT * FROM keystrokes ORDER BY ts ASC"
    ).fetchall()


def count(conn: sqlite3.Connection) -> int:
    return conn.execute("SELECT COUNT(*) FROM keystrokes").fetchone()[0]
