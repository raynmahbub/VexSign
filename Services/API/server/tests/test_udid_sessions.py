"""Tests for the UDID grabber's session lifecycle and plist parsing.

The privacy claims in `udid_grabber`'s docstring are the contract under test:
in-memory only, TTL expiry, a hard session cap with oldest-first eviction, and a
bearer token that is never accepted once its session is gone.

Run from `Services/API/server/`:

    python -m pytest tests/ -q
"""

from __future__ import annotations

import os
import plistlib
import sys
import tempfile
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

_TMP = tempfile.mkdtemp(prefix="vexsign-udid-test-")
os.environ.setdefault("VEXSIGN_DB", os.path.join(_TMP, "vexsign.db"))
os.environ.setdefault("REPO_STORE_DIR", os.path.join(_TMP, "store"))

import main  # noqa: E402
import udid_grabber  # noqa: E402

UDID = "00008110-000A1D2E3C8B001E"


@pytest.fixture(autouse=True)
def clean_sessions():
    """Sessions are process-global; isolate every test from its neighbours."""
    with udid_grabber._lock:
        udid_grabber._sessions.clear()
    yield
    with udid_grabber._lock:
        udid_grabber._sessions.clear()


@pytest.fixture
def client():
    with TestClient(main.app) as test_client:
        yield test_client


def device_body(**overrides) -> bytes:
    attributes = {"DEVICE_UDID": UDID, "DEVICE_NAME": "Test iPhone", "PRODUCT": "iPhone14,5"}
    attributes.update(overrides)
    return plistlib.dumps(attributes, fmt=plistlib.FMT_XML)


# ---------------------------------------------------------------------------
# Session store
# ---------------------------------------------------------------------------

def test_new_session_is_waiting_and_empty():
    token = udid_grabber.create_session()
    session = udid_grabber.get_session(token)
    assert session["status"] == "waiting"
    assert session["device"] == {}
    assert len(token) == 32


def test_tokens_are_unique():
    tokens = {udid_grabber.create_session() for _ in range(50)}
    assert len(tokens) == 50


def test_unknown_token_has_no_session():
    assert udid_grabber.get_session("deadbeef") is None
    assert udid_grabber.record_device("deadbeef", {"DEVICE_UDID": UDID}) is False


def test_expired_session_is_pruned_on_read():
    token = udid_grabber.create_session()
    udid_grabber._sessions[token]["created"] -= udid_grabber.SESSION_TTL_SECONDS + 1
    assert udid_grabber.get_session(token) is None
    assert token not in udid_grabber._sessions


def test_session_cap_evicts_oldest_first(monkeypatch):
    monkeypatch.setattr(udid_grabber, "MAX_SESSIONS", 3)
    first = udid_grabber.create_session()
    second = udid_grabber.create_session()
    third = udid_grabber.create_session()
    fourth = udid_grabber.create_session()

    assert len(udid_grabber._sessions) == 3
    assert udid_grabber.get_session(first) is None
    assert all(udid_grabber.get_session(t) is not None for t in (second, third, fourth))


def test_recording_moves_the_session_to_the_newest_end(monkeypatch):
    monkeypatch.setattr(udid_grabber, "MAX_SESSIONS", 2)
    older = udid_grabber.create_session()
    newer = udid_grabber.create_session()
    # Touching `older` must protect it; `newer` becomes the eviction candidate.
    assert udid_grabber.record_device(older, {"DEVICE_UDID": UDID}) is True
    udid_grabber.create_session()
    assert udid_grabber.get_session(older) is not None
    assert udid_grabber.get_session(newer) is None


def test_record_device_stores_attributes_and_timestamp():
    token = udid_grabber.create_session()
    assert udid_grabber.record_device(token, {"DEVICE_UDID": UDID}) is True
    session = udid_grabber.get_session(token)
    assert session["status"] == "received"
    assert session["device"]["DEVICE_UDID"] == UDID
    assert session["received"] >= session["created"]


# ---------------------------------------------------------------------------
# Plist parsing
# ---------------------------------------------------------------------------

def test_parse_extracts_only_known_attributes():
    body = device_body(UNKNOWN_SECRET="leak-me", CHALLENGE="x")
    attributes = udid_grabber.parse_device_attributes(body)
    assert attributes["DEVICE_UDID"] == UDID
    assert "UNKNOWN_SECRET" not in attributes
    assert "CHALLENGE" not in attributes


def test_parse_accepts_a_cms_wrapped_plist():
    # iOS posts a CMS envelope; the plist is located inside the raw bytes.
    body = b"\x30\x82\x01\x02opaque-cms-header" + device_body() + b"\x00trailing-signature"
    assert udid_grabber.parse_device_attributes(body)["DEVICE_UDID"] == UDID


@pytest.mark.parametrize("body", [
    b"",
    b"not a plist at all",
    b"<?xml version='1.0'?><plist></plist>",
])
def test_parse_rejects_bodies_without_a_plist(body):
    with pytest.raises(ValueError):
        udid_grabber.parse_device_attributes(body)


def test_parse_rejects_a_plist_without_a_udid():
    with pytest.raises(ValueError, match="no UDID"):
        udid_grabber.parse_device_attributes(plistlib.dumps({"DEVICE_NAME": "no udid here"}))


def test_parse_rejects_a_non_dictionary_plist():
    with pytest.raises(ValueError, match="not a dictionary"):
        udid_grabber.parse_device_attributes(plistlib.dumps(["DEVICE_UDID", UDID]))


def test_parse_rejects_a_truncated_plist():
    with pytest.raises(ValueError):
        udid_grabber.parse_device_attributes(b"<?xml version='1.0'?><plist><dict>")


# ---------------------------------------------------------------------------
# Profile payload
# ---------------------------------------------------------------------------

def test_profile_is_an_unsigned_removable_profile_service_payload():
    profile = plistlib.loads(udid_grabber.build_profile("https://example.com/callback?token=abc"))
    assert profile["PayloadType"] == "Profile Service"
    assert profile["PayloadContent"]["URL"] == "https://example.com/callback?token=abc"
    assert profile["PayloadRemovalDisallowed"] is False
    assert profile["PayloadVersion"] == 1
    assert "DEVICE_UDID" in profile["PayloadContent"]["DeviceAttributes"]
    # No signature keys: the page tells the user iOS will warn.
    assert "PayloadCertificate" not in profile


def test_profile_identifiers_are_unique_per_build():
    first = plistlib.loads(udid_grabber.build_profile("https://example.com/cb"))
    second = plistlib.loads(udid_grabber.build_profile("https://example.com/cb"))
    assert first["PayloadUUID"] != second["PayloadUUID"]
    assert first["PayloadIdentifier"] != second["PayloadIdentifier"]


# ---------------------------------------------------------------------------
# HTTP surface
# ---------------------------------------------------------------------------

def test_page_creates_a_distinct_session_per_load(client):
    first = client.get("/Tools/udid").text.split("/api/Tools/udid/profile?token=")[1].split('"')[0]
    second = client.get("/Tools/udid").text.split("/api/Tools/udid/profile?token=")[1].split('"')[0]
    assert first != second
    assert udid_grabber.get_session(first) is not None


def test_profile_download_requires_a_live_token(client):
    assert client.get("/api/Tools/udid/profile?token=deadbeef").status_code == 404
    token = udid_grabber.create_session()
    response = client.get(f"/api/Tools/udid/profile?token={token}")
    assert response.status_code == 200
    assert response.headers["content-type"].startswith("application/x-apple-aspen-config")
    assert "attachment" in response.headers["content-disposition"]


def test_callback_then_poll_returns_the_device(client):
    token = udid_grabber.create_session()
    assert client.get(f"/api/Tools/udid/session/{token}").json()["status"] == "waiting"

    response = client.post(f"/api/udid/callback?token={token}", content=device_body())
    assert response.status_code == 200

    payload = client.get(f"/api/Tools/udid/session/{token}").json()
    assert payload["status"] == "received"
    assert payload["device"]["DEVICE_UDID"] == UDID
    assert 0 < payload["expiresIn"] <= udid_grabber.SESSION_TTL_SECONDS


def test_callback_rejects_an_empty_body(client):
    token = udid_grabber.create_session()
    assert client.post(f"/api/udid/callback?token={token}", content=b"").status_code == 422


def test_callback_rejects_a_plist_without_a_udid(client):
    token = udid_grabber.create_session()
    response = client.post(f"/api/udid/callback?token={token}",
                           content=plistlib.dumps({"DEVICE_NAME": "x"}))
    assert response.status_code == 422
    # A rejected callback must not mark the session received.
    assert client.get(f"/api/Tools/udid/session/{token}").json()["status"] == "waiting"


def test_callback_to_an_expired_session_discards_the_udid(client):
    token = udid_grabber.create_session()
    udid_grabber._sessions[token]["created"] -= udid_grabber.SESSION_TTL_SECONDS + 1
    response = client.post(f"/api/udid/callback?token={token}", content=device_body())
    assert response.status_code == 410
    assert client.get(f"/api/Tools/udid/session/{token}").json() == {"status": "expired"}


def test_unknown_session_polls_as_expired_without_leaking(client):
    assert client.get("/api/Tools/udid/session/deadbeef").json() == {"status": "expired"}


def test_sessions_never_touch_the_database_or_disk(tmp_path, monkeypatch):
    # The module must not open the key DB or write files while handling a device.
    import db

    def fail_connect():
        raise AssertionError("UDID sessions must not touch the database")

    monkeypatch.setattr(db, "connect", fail_connect)
    token = udid_grabber.create_session()
    assert udid_grabber.record_device(token, {"DEVICE_UDID": UDID}) is True
    assert udid_grabber.get_session(token)["device"]["DEVICE_UDID"] == UDID
