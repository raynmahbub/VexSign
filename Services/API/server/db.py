#!/usr/bin/env python3
"""Tiny SQLite-backed storage for VexSign premium API keys.

A key row looks like:

    api_key      TEXT PRIMARY KEY  -- e.g. VEX-ABCD-EFGH-IJKL
    used         INTEGER           -- 0 = fresh, 1 = consumed by a device
    device_uuid  TEXT              -- the VexSign device that consumed it
    disabled     INTEGER           -- 1 = administratively disabled (403)
    created_at   REAL              -- unix timestamp
"""

import os
import sqlite3
import sys
import time

# Default DB lives next to this file (writable everywhere, including Render
# free tier where /data isn't mounted and not writable). Override with
# VEXSIGN_DB when you actually have a persistent disk mounted (paid plan).
_DEFAULT_DB = os.path.join(os.path.dirname(os.path.abspath(__file__)), "vexsign.db")


def _resolve_db_path() -> str:
    env = os.environ.get("VEXSIGN_DB")
    if not env:
        return _DEFAULT_DB

    # If the configured path's parent is writable (e.g. /data on a paid Render
    # plan with a mounted disk), use it. Otherwise fall back to the default
    # rather than crashing at startup on free-tier / sandbox hosts.
    parent = os.path.dirname(os.path.abspath(env)) or "."
    if os.path.exists(parent) and os.access(parent, os.W_OK):
        return env
    # Try creating the parent; if that fails, fall back.
    try:
        os.makedirs(parent, exist_ok=True)
        return env
    except (PermissionError, OSError) as exc:
        print(
            f"[db] VEXSIGN_DB={env!r} is not writable ({exc}); "
            f"falling back to {_DEFAULT_DB}",
            file=sys.stderr,
        )
        return _DEFAULT_DB


DB_PATH = _resolve_db_path()

# Shared with keygen.py and the admin API: keep O/0 and I/1 out of keys so a
# key read off a phone screen and typed back is never ambiguous.
KEY_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

_SCHEMA = """
CREATE TABLE IF NOT EXISTS keys (
    api_key     TEXT PRIMARY KEY,
    used        INTEGER NOT NULL DEFAULT 0,
    device_uuid TEXT,
    disabled    INTEGER NOT NULL DEFAULT 0,
    created_at  REAL NOT NULL
);
"""


def connect() -> sqlite3.Connection:
    """Open the database (creating the schema on first use)."""
    parent = os.path.dirname(os.path.abspath(DB_PATH))
    if parent:
        os.makedirs(parent, exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.executescript(_SCHEMA)
    return conn


def add_key(api_key: str) -> None:
    with connect() as conn:
        conn.execute(
            "INSERT INTO keys (api_key, used, device_uuid, disabled, created_at) VALUES (?, 0, NULL, 0, ?)",
            (api_key, time.time()),
        )


def get_key(api_key: str) -> sqlite3.Row | None:
    with connect() as conn:
        return conn.execute("SELECT * FROM keys WHERE api_key = ?", (api_key,)).fetchone()


def consume_key(api_key: str, device_uuid: str) -> bool:
    """Mark a fresh key as used and bind it to a device (atomic and idempotent).
    Returns True if successfully claimed, False if already claimed or disabled."""
    with connect() as conn:
        cursor = conn.execute(
            "UPDATE keys SET used = 1, device_uuid = ? WHERE api_key = ? AND used = 0 AND disabled = 0",
            (device_uuid, api_key),
        )
        return cursor.rowcount > 0


def device_has_activation(device_uuid: str) -> bool:
    with connect() as conn:
        row = conn.execute(
            "SELECT 1 FROM keys WHERE device_uuid = ? AND used = 1 AND disabled = 0 LIMIT 1",
            (device_uuid,),
        ).fetchone()
        return row is not None


def key_allows_downloads(api_key: str) -> bool:
    """A consumed, non-disabled key may download premium content."""
    row = get_key(api_key)
    return bool(row and row["used"] and not row["disabled"])


def set_key_disabled(api_key: str, disabled: bool) -> None:
    """Administratively disable (or re-enable) a key."""
    with connect() as conn:
        conn.execute(
            "UPDATE keys SET disabled = ? WHERE api_key = ?",
            (int(disabled), api_key),
        )


def reset_key(api_key: str) -> None:
    """Make a consumed key fresh again (unbind its device)."""
    with connect() as conn:
        conn.execute(
            "UPDATE keys SET used = 0, device_uuid = NULL WHERE api_key = ?",
            (api_key,),
        )


def delete_key(api_key: str) -> None:
    """Permanently remove a key."""
    with connect() as conn:
        conn.execute("DELETE FROM keys WHERE api_key = ?", (api_key,))
