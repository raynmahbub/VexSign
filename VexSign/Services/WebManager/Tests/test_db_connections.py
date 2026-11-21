"""Connection lifetime in db.py.

`with sqlite3.connect() as conn` commits or rolls back, it does not close. Every
request used to leave its connection open until a garbage collection happened to
run, which leaks one file descriptor per request under sustained traffic.

Run from `VexSign/Services/WebManager/API/`:

    python -m pytest ../Tests/ -q
"""

from __future__ import annotations

import os
import sqlite3
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "API"))

import db  # noqa: E402


@pytest.fixture
def isolated_db(tmp_path, monkeypatch):
    monkeypatch.setattr(db, "DB_PATH", str(tmp_path / "keys.db"))
    return tmp_path / "keys.db"


def test_explicit_db_path_is_created_without_falling_back(tmp_path, monkeypatch):
    configured = tmp_path / "persistent" / "keys.db"
    monkeypatch.setenv("VEXSIGN_DB", str(configured))
    assert db._resolve_db_path() == str(configured)
    assert configured.parent.is_dir()


def test_explicit_db_path_refuses_unwritable_parent(tmp_path, monkeypatch):
    configured = tmp_path / "persistent" / "keys.db"
    configured.parent.mkdir()
    monkeypatch.setenv("VEXSIGN_DB", str(configured))
    monkeypatch.setattr(db.os, "access", lambda _path, _mode: False)
    with pytest.raises(RuntimeError, match="VEXSIGN_DB directory"):
        db._resolve_db_path()


def test_explicit_db_path_refuses_invalid_parent(tmp_path, monkeypatch):
    parent = tmp_path / "not-a-directory"
    parent.write_text("file")
    monkeypatch.setenv("VEXSIGN_DB", str(parent / "keys.db"))
    with pytest.raises(RuntimeError, match="VEXSIGN_DB directory"):
        db._resolve_db_path()


def test_unset_db_path_uses_documented_default(monkeypatch):
    monkeypatch.delenv("VEXSIGN_DB", raising=False)
    assert db._resolve_db_path() == db._DEFAULT_DB


def _open_descriptors() -> int | None:
    """Linux-only descriptor count; skipped elsewhere so the suite stays portable."""
    try:
        return len(os.listdir("/proc/self/fd"))
    except OSError:  # pragma: no cover - not Linux
        return None


def test_connection_is_closed_after_the_block(isolated_db):
    with db.connection() as conn:
        assert conn.execute("SELECT 1").fetchone()[0] == 1

    with pytest.raises(sqlite3.ProgrammingError):
        conn.execute("SELECT 1")


def test_connection_closes_after_an_exception_and_rolls_back(isolated_db):
    db.add_key("VEX-AAAA-BBBB-CCCC")

    with pytest.raises(RuntimeError):
        with db.connection() as conn:
            conn.execute("UPDATE keys SET used = 1, device_uuid = 'x' WHERE api_key = ?",
                         ("VEX-AAAA-BBBB-CCCC",))
            raise RuntimeError("boom")

    row = db.get_key("VEX-AAAA-BBBB-CCCC")
    assert row["used"] == 0, "a failed transaction must not commit"


def test_repeated_calls_do_not_leak_file_descriptors(isolated_db):
    db.add_key("VEX-AAAA-BBBB-CCCC")
    before = _open_descriptors()
    if before is None:  # pragma: no cover - not Linux
        pytest.skip("no /proc/self/fd on this platform")

    for _ in range(300):
        db.get_key("VEX-AAAA-BBBB-CCCC")
        db.device_has_activation("device-1")

    assert _open_descriptors() - before <= 1, "each call must close its connection"


def test_writes_are_visible_to_a_later_connection(isolated_db):
    db.add_key("VEX-DDDD-EEEE-FFFF")
    assert db.consume_key("VEX-DDDD-EEEE-FFFF", "device-1") is True
    assert db.device_has_activation("device-1") is True

    # Committed by the context manager, not merely visible inside it.
    with db.connection() as conn:
        stored = conn.execute(
            "SELECT device_uuid FROM keys WHERE api_key = ?", ("VEX-DDDD-EEEE-FFFF",)
        ).fetchone()
    assert stored["device_uuid"] == "device-1"


def test_database_uses_write_ahead_logging(isolated_db):
    """WAL keeps the app-facing read routes working during an admin write."""
    db.add_key("VEX-GGGG-HHHH-IIII")
    with db.connection() as conn:
        mode = conn.execute("PRAGMA journal_mode").fetchone()[0]
    assert mode.lower() == "wal"


def test_busy_timeout_is_applied(isolated_db):
    with db.connection() as conn:
        timeout_ms = conn.execute("PRAGMA busy_timeout").fetchone()[0]
    assert timeout_ms == int(db.BUSY_TIMEOUT_SECONDS * 1000)
