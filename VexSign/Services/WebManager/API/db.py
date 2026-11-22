#!/usr/bin/env python3
"""Tiny SQLite-backed storage for VexSign premium API keys.

A key row looks like:

    api_key      TEXT PRIMARY KEY  -- e.g. VEX-ABCD-EFGH-IJKL
    used         INTEGER           -- 0 = fresh, 1 = consumed by a device
    device_uuid  TEXT              -- the VexSign device that consumed it
    disabled     INTEGER           -- 1 = administratively disabled (403)
    created_at   REAL              -- unix timestamp
"""

import contextlib
import os
import sqlite3
import threading
import time

# How long a writer waits for another writer before raising "database is
# locked". Also set as a PRAGMA so it applies to every statement, not just the
# connect() handshake.
BUSY_TIMEOUT_SECONDS = 5.0

# Default DB lives next to this file (writable everywhere, including Render
# free tier where /data isn't mounted and not writable). Override with
# VEXSIGN_DB when you actually have a persistent disk mounted (paid plan).
_DEFAULT_DB = os.path.join(os.path.dirname(os.path.abspath(__file__)), "vexsign.db")


def _resolve_db_path() -> str:
    env = os.environ.get("VEXSIGN_DB")
    if not env:
        return _DEFAULT_DB

    # An explicit location is an operator's persistence choice. Falling back to
    # the ephemeral default can silently lose activations after a redeploy, so a
    # broken configuration must fail rather than writing a different database.
    parent = os.path.dirname(os.path.abspath(env)) or "."
    try:
        os.makedirs(parent, exist_ok=True)
        if not os.path.isdir(parent) or not os.access(parent, os.W_OK):
            raise OSError("database directory is not writable")
    except OSError as exc:
        raise RuntimeError(f"VEXSIGN_DB directory {parent!r} is unavailable or not writable") from exc
    return env


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
CREATE INDEX IF NOT EXISTS idx_keys_device_uuid ON keys(device_uuid);
"""

_INIT_LOCK = threading.Lock()
_INITIALIZED_DBS: set[tuple[str, int]] = set()


def _db_file_key(path: str) -> tuple[str, int] | None:
    if path == ":memory:" or path.startswith("file:"):
        return None
    abs_path = os.path.abspath(path)
    try:
        st = os.stat(abs_path)
    except OSError:
        return None
    if st.st_size <= 0:
        return None
    return (abs_path, st.st_ino)


def connect() -> sqlite3.Connection:
    """Open the database (creating the schema on first use).

    The caller owns the returned connection and must close it. Prefer
    `connection()`, which does that on every exit path: `with sqlite3.connect()`
    only commits or rolls back, it does not close, so every request used to leak
    one file descriptor until the garbage collector happened to run.
    """
    parent = os.path.dirname(os.path.abspath(DB_PATH))
    if parent:
        os.makedirs(parent, exist_ok=True)
    existing_key = _db_file_key(DB_PATH)
    with _INIT_LOCK:
        already_initialized = existing_key is not None and existing_key in _INITIALIZED_DBS
    conn = sqlite3.connect(DB_PATH, timeout=BUSY_TIMEOUT_SECONDS)
    conn.row_factory = sqlite3.Row
    conn.execute(f"PRAGMA busy_timeout = {int(BUSY_TIMEOUT_SECONDS * 1000)}")
    if not already_initialized:
        # WAL lets the app-facing read routes run while an admin request writes.
        # A database on a read-only or unsupported filesystem keeps its old journal
        # mode rather than failing the request that triggered the pragma.
        try:
            conn.execute("PRAGMA journal_mode = WAL")
        except sqlite3.Error:
            pass
        conn.executescript(_SCHEMA)
        new_key = _db_file_key(DB_PATH)
        if new_key is not None:
            with _INIT_LOCK:
                _INITIALIZED_DBS.add(new_key)
    return conn


@contextlib.contextmanager
def connection():
    """Borrow a connection for one transaction and always close it."""
    conn = connect()
    try:
        with conn:  # commit on success, roll back on exception
            yield conn
    finally:
        conn.close()


def add_key(api_key: str) -> None:
    with connection() as conn:
        conn.execute(
            "INSERT INTO keys (api_key, used, device_uuid, disabled, created_at) VALUES (?, 0, NULL, 0, ?)",
            (api_key, time.time()),
        )


def get_key(api_key: str) -> sqlite3.Row | None:
    with connection() as conn:
        return conn.execute("SELECT * FROM keys WHERE api_key = ?", (api_key,)).fetchone()


_ORIGINAL_GET_KEY = get_key


def consume_key(api_key: str, device_uuid: str) -> bool:
    """Mark a fresh key as used and bind it to a device (atomic and idempotent).
    Returns True if successfully claimed, False if already claimed or disabled."""
    with connection() as conn:
        cursor = conn.execute(
            "UPDATE keys SET used = 1, device_uuid = ? WHERE api_key = ? AND used = 0 AND disabled = 0",
            (device_uuid, api_key),
        )
        return cursor.rowcount > 0


def device_has_activation(device_uuid: str) -> bool:
    with connection() as conn:
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
    with connection() as conn:
        conn.execute(
            "UPDATE keys SET disabled = ? WHERE api_key = ?",
            (int(disabled), api_key),
        )


def reset_key(api_key: str) -> None:
    """Make a consumed key fresh again (unbind its device)."""
    with connection() as conn:
        conn.execute(
            "UPDATE keys SET used = 0, device_uuid = NULL WHERE api_key = ?",
            (api_key,),
        )


def delete_key(api_key: str) -> None:
    """Permanently remove a key."""
    with connection() as conn:
        conn.execute("DELETE FROM keys WHERE api_key = ?", (api_key,))
