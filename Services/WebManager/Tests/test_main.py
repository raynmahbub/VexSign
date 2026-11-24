"""Tests for the premium key flow and deployment hardening in main.py.

Run from `Services/WebManager/API/`:

    python -m pytest ../Tests/ -q
"""

from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "API"))

_TMP = tempfile.mkdtemp(prefix="vexsign-test-")
os.environ.setdefault("VEXSIGN_DB", os.path.join(_TMP, "vexsign.db"))
os.environ.setdefault("REPO_STORE_DIR", os.path.join(_TMP, "store"))
os.environ["ADMIN_TOKEN"] = "test-admin-token"
os.environ["SEED_KEYS"] = "VEX-AAAA-BBBB-CCCC,VEX-DDDD-EEEE-FFFF"

import db  # noqa: E402
import main  # noqa: E402


@pytest.fixture
def client():
    with TestClient(main.app) as test_client:
        yield test_client


def test_static_icon_uses_the_flat_dashboard_directory(client):
    expected = Path(__file__).resolve().parents[1] / "Dashboard/icon.png"
    response = client.get("/static/icon.png")
    assert response.status_code == 200
    assert response.headers["content-type"] == "image/png"
    assert response.content == expected.read_bytes()


def test_validate_accepts_lowercase_and_padded_keys(client):
    response = client.post(
        "/api/validate",
        json={"device_uuid": "device-1"},
        headers={"X-API-Key": "  vex-aaaa-bbbb-cccc  "},
    )
    assert response.status_code == 200, response.text
    assert response.json()["urls"], "validate must return a non-empty urls list"


def test_validate_still_binds_and_rejects_other_devices(client):
    first = client.post(
        "/api/validate",
        json={"device_uuid": "device-2"},
        headers={"X-API-Key": "VEX-DDDD-EEEE-FFFF"},
    )
    assert first.status_code == 200, first.text

    # Same device may re-validate (idempotent); another device is rejected
    # with the exact burned-key message the app shows.
    assert (
        client.post(
            "/api/validate",
            json={"device_uuid": "device-2"},
            headers={"X-API-Key": "VEX-DDDD-EEEE-FFFF"},
        ).status_code
        == 200
    )
    other = client.post(
        "/api/validate",
        json={"device_uuid": "someone-else"},
        headers={"X-API-Key": "VEX-DDDD-EEEE-FFFF"},
    )
    assert other.status_code == 401
    assert other.json()["detail"] == main.INVALID_KEY_DETAIL


def test_validate_rejects_blank_device_uuid(client):
    response = client.post(
        "/api/validate",
        json={"device_uuid": "   "},
        headers={"X-API-Key": "VEX-AAAA-BBBB-CCCC"},
    )
    assert response.status_code == 422
    assert isinstance(response.json()["detail"], str)


def test_validation_errors_are_a_plain_string_detail(client):
    response = client.post(
        "/api/validate", json={}, headers={"X-API-Key": "VEX-AAAA-BBBB-CCCC"}
    )
    assert response.status_code == 422
    # The app decodes `{"detail": String}` — a list here used to break that.
    payload = response.json()
    assert isinstance(payload['detail'], str)


def test_gated_feed_accepts_normalised_key_header(client):
    # VEX-AAAA-BBBB-CCCC was bound to device-1 above; re-validating with the
    # same device is idempotent and keeps this test order-independent.
    client.post(
        "/api/validate",
        json={"device_uuid": "device-1"},
        headers={"X-API-Key": "VEX-AAAA-BBBB-CCCC"},
    )
    response = client.get(
        "/repo/premium.json", headers={"X-API-Key": "vex-aaaa-bbbb-cccc"}
    )
    assert response.status_code == 200, response.text
    assert response.json()["apps"], "premium feed must carry a non-empty apps array"


def test_chained_forwarding_headers_do_not_poison_feed_urls(client):
    response = client.get(
        "/",
        headers={
            "X-Forwarded-Proto": "https, http",
            "X-Forwarded-Host": "vexsign-premium.onrender.com, internal:10000",
        },
    )
    setting = response.json()["appSetting"]
    assert "https://vexsign-premium.onrender.com/api" in setting
    assert "," not in setting.split('"')[1]


def test_onrender_without_forwarded_proto_stays_https(client):
    response = client.get("/", headers={"Host": "vexsign-premium.onrender.com"})
    # TestClient's request URL is http://testserver; the host override alone
    # must still yield an ATS-safe https base for known TLS-terminating hosts.
    assert response.json()["appSetting"].startswith(
        'static let apiBaseURL = "https://vexsign-premium.onrender.com/api"'
    )


def test_landing_page_never_reflects_a_malicious_host(client):
    """A Host header that is not a host token is dropped, not echoed.

    HTML-escaping the value was the earlier defence; `request_base.safe_host`
    now rejects it outright, so the page falls back to the loopback name and the
    attacker-controlled string never reaches the response in any form.
    """
    payload = 'evil.example.com"><script>alert(1)</script>'
    response = client.get("/", headers={"Host": payload, "Accept": "text/html"})
    assert response.status_code == 200
    assert "<script>alert(1)</script>" not in response.text
    assert "&lt;script&gt;" not in response.text
    assert 'evil.example.com"' not in response.text
    assert "localhost" in response.text


def test_db_helpers_tolerate_missing_device():
    assert db.device_has_activation("no-such-device") is False
    assert db.key_allows_downloads("VEX-NOT-A-REAL-KEY") is False
