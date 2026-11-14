"""Tests for the browser tools: repo creator, certificate checker, UDID grabber.

Run from `Services/API/server/`:

    python -m pytest tests/ -q
"""

from __future__ import annotations

import os
import plistlib
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

_TMP = tempfile.mkdtemp(prefix="vexsign-webtools-test-")
os.environ.setdefault("VEXSIGN_DB", os.path.join(_TMP, "vexsign.db"))
os.environ.setdefault("REPO_STORE_DIR", os.path.join(_TMP, "store"))

import cert_inspector  # noqa: E402
import main  # noqa: E402
import repo_creator  # noqa: E402
import udid_grabber  # noqa: E402

try:  # optional server dependency; the cert test below is skipped without it
    import cryptography  # noqa: F401

    _HAS_CRYPTOGRAPHY = True
except ImportError:
    _HAS_CRYPTOGRAPHY = False


@pytest.fixture
def client():
    with TestClient(main.app) as test_client:
        yield test_client


def _draft(**overrides):
    draft = {
        "name": "Test Repository",
        "identifier": "com.example.test",
        "iconURL": "https://example.com/icon.png",
        "sourceURL": "https://example.com/source.json",
        "apps": [
            {
                "name": "Test App",
                "bundleIdentifier": "com.example.test.app",
                "version": "1.2.3",
                "versionDate": "2026-01-31T12:00:00Z",
                "developerName": "Example",
                "downloadURL": "https://example.com/app.ipa",
                "iconURL": "https://example.com/app.png",
                "size": 12345678,
                "category": "Utilities",
                "localizedDescription": "A test app.",
                "screenshotURLs": ["https://example.com/1.png"],
            }
        ],
    }
    draft.update(overrides)
    return draft


# ---------------------------------------------------------------------------
# Hub
# ---------------------------------------------------------------------------

def test_hub_links_every_tool(client):
    response = client.get("/tools")
    assert response.status_code == 200, response.text
    for href in ("/Tools/repo-creator", "/Tools/cert-check", "/Tools/udid"):
        assert href in response.text
    assert "text/html" in response.headers["content-type"]


def test_landing_page_advertises_tools(client):
    response = client.get("/", headers={"Accept": "text/html"})
    assert response.status_code == 200
    assert "/tools" in response.text


def test_tool_pages_render(client):
    for path in ("/Tools/repo-creator", "/Tools/cert-check"):
        response = client.get(path)
        assert response.status_code == 200, path
        assert "<!doctype html>" in response.text


# ---------------------------------------------------------------------------
# Repository creator
# ---------------------------------------------------------------------------

def test_validate_clean_draft_has_no_errors(client):
    response = client.post("/api/Tools/repo/validate", json={"draft": _draft()})
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["errorCount"] == 0, body["issues"]
    assert body["appCount"] == 1


def test_validate_reports_missing_fields_and_insecure_urls(client):
    valid = _draft()["apps"][0]
    # app0 keeps the original bundle id; app1 duplicates it; app2 has none.
    duplicate = dict(valid, downloadURL="http://example.com/app.ipa")
    broken = dict(
        valid,
        name="Broken App",
        bundleIdentifier="",
        versionDate="not-a-date",
        screenshotURLs=["https://example.com/1.png", "https://example.com/1.png"],
    )
    draft = _draft(apps=[valid, duplicate, broken])

    body = client.post("/api/Tools/repo/validate", json={"draft": draft}).json()
    messages = " ".join(issue["message"] for issue in body["issues"])
    assert body["errorCount"] >= 3
    assert "has no bundle identifier" in messages
    assert "cleartext http" in messages
    assert "ISO-8601" in messages
    assert "duplicate screenshot" in messages
    assert "“com.example.test.app” appears 2 times" in messages
    # Errors are reported before warnings.
    severities = [issue["severity"] for issue in body["issues"]]
    assert severities == sorted(severities, key=lambda s: 0 if s == "error" else 1)


def test_export_altstore_includes_versions_history(client):
    body = client.post(
        "/api/Tools/repo/export", json={"draft": _draft(), "format": "altstore"}
    ).json()
    assert body["filename"] == "source.json"
    source = __import__("json").loads(body["json"])
    assert source["identifier"] == "com.example.test"
    app = source["apps"][0]
    assert app["versions"][0]["version"] == "1.2.3"
    assert app["versions"][0]["downloadURL"] == "https://example.com/app.ipa"


def test_export_flat_drops_versions(client):
    body = client.post(
        "/api/Tools/repo/export", json={"draft": _draft(), "format": "flat"}
    ).json()
    source = __import__("json").loads(body["json"])
    assert "versions" not in source["apps"][0]
    assert source["apps"][0]["downloadURL"] == "https://example.com/app.ipa"


def test_export_apps_json_is_a_bare_array(client):
    body = client.post(
        "/api/Tools/repo/export", json={"draft": _draft(), "format": "apps"}
    ).json()
    assert body["filename"] == "apps.json"
    payload = __import__("json").loads(body["json"])
    assert isinstance(payload, list) and payload[0]["bundleIdentifier"] == "com.example.test.app"


def test_export_rejects_unknown_format(client):
    response = client.post(
        "/api/Tools/repo/export", json={"draft": _draft(), "format": "nope"}
    )
    assert response.status_code == 422
    assert "Unknown export format" in response.json()["detail"]


def test_ota_requires_https_manifest_and_ipa(client):
    app = _draft()["apps"][0]
    response = client.post(
        "/api/Tools/repo/ota", json={"app": app, "manifestURL": "http://example.com/m.plist"}
    )
    assert response.status_code == 422
    assert "https" in response.json()["detail"]

    cleartext = dict(app, downloadURL="http://example.com/app.ipa")
    response = client.post(
        "/api/Tools/repo/ota", json={"app": cleartext, "manifestURL": "https://example.com/m.plist"}
    )
    assert response.status_code == 422


def test_ota_manifest_is_a_valid_software_package(client):
    app = _draft()["apps"][0]
    body = client.post(
        "/api/Tools/repo/ota",
        json={
            "app": app,
            "manifestURL": "https://example.com/manifest.plist",
            "displayImageURL": "https://example.com/icon.png",
        },
    ).json()

    manifest = plistlib.loads(body["manifest"].encode("utf-8"))
    item = manifest["items"][0]
    assert item["metadata"]["bundle-identifier"] == "com.example.test.app"
    assert item["metadata"]["bundle-version"] == "1.2.3"
    kinds = [asset["kind"] for asset in item["assets"]]
    assert kinds == ["software-package", "display-image"]
    # The manifest URL is fully percent-encoded, as itms-services:// requires.
    assert body["installLink"] == (
        "itms-services://?action=download-manifest&url=https%3A%2F%2Fexample.com%2Fmanifest.plist"
    )


def test_validator_is_shared_between_api_and_module():
    """The page and the API must not disagree about what a valid feed is."""
    issues = repo_creator.validate_draft(repo_creator.RepoDraft(**_draft()))
    assert issues == []


# ---------------------------------------------------------------------------
# Certificate status checker
# ---------------------------------------------------------------------------

def _profile_bytes(expires_in_days: int = 90, **overrides) -> bytes:
    now = datetime.now(timezone.utc)
    payload = {
        "AppIDName": "Test App",
        "CreationDate": now - timedelta(days=30),
        "ExpirationDate": now + timedelta(days=expires_in_days),
        "Name": "Test Profile",
        "TeamIdentifier": ["TESTTEAM"],
        "TeamName": "Test Team",
        "TimeToLive": 365,
        "UUID": "11111111-2222-3333-4444-555555555555",
        "Version": 1,
        "Platform": ["iOS"],
        "ProvisionedDevices": ["00008110-0000000000000000"],
        "Entitlements": {
            "application-identifier": "TESTTEAM.com.example.test",
            "get-task-allow": True,
            "aps-environment": "development",
        },
    }
    payload.update(overrides)
    xml = plistlib.dumps(payload, fmt=plistlib.FMT_XML)
    # Real profiles wrap the plist in a CMS blob; the parser must ignore the
    # surrounding bytes, so emulate that with junk on both sides.
    return b"\x30\x82\x00\x06\x06\x09junk-before" + xml + b"\x00junk-after"


def test_inspect_parses_a_provisioning_profile(client):
    response = client.post(
        "/api/Tools/cert/inspect",
        files={"file": ("Profile.mobileprovision", _profile_bytes(), "application/octet-stream")},
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["kind"] == "provisioning-profile"
    assert body["status"] == "valid"
    assert body["name"] == "Test Profile"
    assert body["teamName"] == "Test Team"
    assert body["deviceCount"] == 1
    assert body["provisionsAllDevices"] is False
    assert body["notable"]["get-task-allow"] is True
    assert body["daysRemaining"] >= 88
    assert body["revocation"]["status"] == "unknown"


def test_inspect_flags_an_expired_profile(client):
    response = client.post(
        "/api/Tools/cert/inspect",
        files={"file": ("Profile.mobileprovision", _profile_bytes(expires_in_days=-5), "application/octet-stream")},
    )
    body = response.json()
    assert body["status"] == "expired"
    assert body["daysRemaining"] < 0


def test_inspect_flags_a_profile_expiring_within_a_week(client):
    response = client.post(
        "/api/Tools/cert/inspect",
        files={"file": ("Profile.mobileprovision", _profile_bytes(expires_in_days=3), "application/octet-stream")},
    )
    assert response.json()["status"] == "critical"


def test_inspect_refuses_p12_and_garbage(client):
    response = client.post(
        "/api/Tools/cert/inspect",
        files={"file": ("cert.p12", b"\x30\x82\x01\x00notreally", "application/octet-stream")},
    )
    assert response.status_code == 422
    assert "never takes a certificate bundle" in response.json()["detail"]

    response = client.post(
        "/api/Tools/cert/inspect",
        files={"file": ("notes.txt", b"hello world", "text/plain")},
    )
    assert response.status_code == 422
    assert "never a .p12" in response.json()["detail"]


def test_revocation_lookup_uses_the_curated_list(monkeypatch, tmp_path):
    listed = tmp_path / "revoked_certs.json"
    listed.write_text(
        '[{"sha1": "aabbccddeeff00112233445566778899aabbccdd", "label": "Test cert"}]',
        encoding="utf-8",
    )
    monkeypatch.setattr(cert_inspector, "REVOKED_LIST_PATH", str(listed))

    found = cert_inspector.check_revocation("AABBCCDDEEFF00112233445566778899AABBCCDD", None)
    assert found["listed"] is True and found["status"] == "revoked" and found["label"] == "Test cert"

    missing = cert_inspector.check_revocation("0000", None)
    assert missing["listed"] is False
    assert missing["status"] == "unknown"
    # Absence from the list must never be reported as "not revoked".
    assert "not proof" in missing["note"]


def test_shipped_revocation_list_is_empty_and_valid():
    assert cert_inspector.revoked_list() == []


@pytest.mark.skipif(not _HAS_CRYPTOGRAPHY, reason="optional `cryptography` not installed")
def test_inspect_parses_a_public_certificate(client):
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.x509.oid import NameOID

    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "VexSign Test CA")])
    now = datetime.now(timezone.utc)
    cert = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(subject)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - timedelta(days=1))
        .not_valid_after(now + timedelta(days=364))
        .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
        .sign(key, hashes.SHA256())
    )
    pem = cert.public_bytes(serialization.Encoding.PEM)

    body = client.post(
        "/api/Tools/cert/inspect", files={"file": ("cert.pem", pem, "application/x-pem-file")}
    ).json()
    assert body["kind"] == "certificate"
    assert body["encoding"] == "pem"
    assert body["status"] == "valid"
    assert "VexSign Test CA" in body["subject"]
    assert body["isCA"] is True
    assert body["sha256"] == cert_inspector.parse_certificate(pem)["sha256"]
    assert len(body["sha1"]) == 40 and len(body["sha256"]) == 64


# ---------------------------------------------------------------------------
# UDID grabber
# ---------------------------------------------------------------------------

def test_udid_profile_is_a_profile_service_payload(client):
    page = client.get("/Tools/udid")
    assert page.status_code == 200
    token = page.text.split("/api/Tools/udid/profile?token=")[1].split('"')[0]

    response = client.get(f"/api/Tools/udid/profile?token={token}")
    assert response.status_code == 200
    assert response.headers["content-type"].startswith("application/x-apple-aspen-config")

    profile = plistlib.loads(response.content)
    assert profile["PayloadType"] == "Profile Service"
    assert profile["PayloadVersion"] == 1
    assert "DEVICE_UDID" in profile["PayloadContent"]["DeviceAttributes"]
    assert f"/api/udid/callback?token={token}" in profile["PayloadContent"]["URL"]


def test_udid_profile_rejects_unknown_token(client):
    response = client.get("/api/Tools/udid/profile?token=deadbeef")
    assert response.status_code == 404


def test_udid_callback_records_the_device(client):
    token = udid_grabber.create_session()
    assert client.get(f"/api/Tools/udid/session/{token}").json()["status"] == "waiting"

    # iOS posts the attribute plist as the raw (signed) body.
    body = b"\x30\x82\x00\x06junk" + plistlib.dumps(
        {
            "DEVICE_NAME": "Test iPhone",
            "DEVICE_UDID": "00008110-000A1B2C3D4E5F60",
            "PRODUCT": "iPhone15,3",
            "VERSION": "26.0",
            "SERIAL": "C02TESTSERIAL",
        },
        fmt=plistlib.FMT_XML,
    ) + b"trailing"

    posted = client.post(
        f"/api/udid/callback?token={token}",
        content=body,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    assert posted.status_code == 200, posted.text

    session = client.get(f"/api/Tools/udid/session/{token}").json()
    assert session["status"] == "received"
    assert session["device"]["DEVICE_UDID"] == "00008110-000A1B2C3D4E5F60"
    assert session["device"]["PRODUCT"] == "iPhone15,3"


def test_udid_callback_after_expiry_is_discarded(client):
    token = udid_grabber.create_session()
    udid_grabber._sessions[token]["created"] -= udid_grabber.SESSION_TTL_SECONDS + 1

    body = plistlib.dumps({"DEVICE_UDID": "00000000-0000000000000000"}, fmt=plistlib.FMT_XML)
    response = client.post(f"/api/udid/callback?token={token}", content=body)
    assert response.status_code == 410
    assert client.get(f"/api/Tools/udid/session/{token}").json()["status"] == "expired"


def test_udid_callback_rejects_a_body_without_a_udid(client):
    token = udid_grabber.create_session()
    body = plistlib.dumps({"PRODUCT": "iPhone15,3"}, fmt=plistlib.FMT_XML)
    response = client.post(f"/api/udid/callback?token={token}", content=body)
    assert response.status_code == 422
    assert "no UDID" in response.json()["detail"]


def test_udid_sessions_are_capped():
    udid_grabber._sessions.clear()
    for _ in range(udid_grabber.MAX_SESSIONS + 5):
        udid_grabber.create_session()
    assert len(udid_grabber._sessions) <= udid_grabber.MAX_SESSIONS
