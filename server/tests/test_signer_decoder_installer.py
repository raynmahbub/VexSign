"""Tests for the signer console, repository decoder and app installer.

Run from `server/`:

    python -m pytest tests/ -q

The relay/probe endpoints would otherwise hit real hosts, so every outbound call
goes through an `httpx.MockTransport` substituted for the module's client
factory. Nothing here touches the network.
"""

from __future__ import annotations

import ipaddress
import json
import os
import sys
import tempfile
from pathlib import Path

import httpx
import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

_TMP = tempfile.mkdtemp(prefix="vexsign-tools-test-")
os.environ.setdefault("VEXSIGN_DB", os.path.join(_TMP, "vexsign.db"))
os.environ.setdefault("REPO_STORE_DIR", os.path.join(_TMP, "store"))
os.environ.pop("VEXSIGN_ALLOW_PUBLIC_TARGETS", None)

import app_installer  # noqa: E402
import main  # noqa: E402
import repo_decoder  # noqa: E402
import url_guard  # noqa: E402
import web_signer  # noqa: E402


@pytest.fixture
def client():
    with TestClient(main.app) as test_client:
        yield test_client


def mock_factory(handler, seen: list[httpx.Request] | None = None):
    """Swap a module's client factory for a MockTransport-backed one."""

    def factory():
        transport = httpx.MockTransport(
            (lambda request: (seen.append(request), handler(request))[1]) if seen is not None else handler
        )
        return httpx.Client(transport=transport, follow_redirects=True)

    return factory


# ---------------------------------------------------------------------------
# Signer console
# ---------------------------------------------------------------------------

def test_guard_allows_private_addresses():
    assert web_signer.target_guard_error("http://127.0.0.1:8000") is None
    assert web_signer.target_guard_error("http://192.168.1.20:8000") is None
    assert web_signer.target_guard_error("http://10.0.0.7") is None
    assert web_signer.target_guard_error("http://100.64.0.1:8000") is None  # tailnet/CGNAT
    assert web_signer.target_guard_error("http://192.168.1.20:8000/") is None


def test_guard_refuses_public_and_bad_input():
    assert web_signer.target_guard_error("") is not None
    assert web_signer.target_guard_error("ftp://10.0.0.1") is not None
    refusal = web_signer.target_guard_error("http://93.184.216.34:8000")
    assert refusal is not None
    assert "93.184.216.34" in refusal
    assert "VEXSIGN_ALLOW_PUBLIC_TARGETS" in refusal


def test_guard_can_be_relaxed_by_env(monkeypatch):
    monkeypatch.setenv("VEXSIGN_ALLOW_PUBLIC_TARGETS", "1")
    assert web_signer.target_guard_error("http://93.184.216.34:8000") is None


def test_proxy_rejects_public_target(client):
    response = client.post(
        "/api/tools/sign/proxy",
        json={"baseURL": "http://93.184.216.34:8000", "path": "status"},
    )
    assert response.status_code == 422
    assert "private" in response.json()["detail"]


def test_proxy_rejects_write_paths(client):
    """The relay is read-only: POST /api/cleanup must not be reachable."""
    response = client.post(
        "/api/tools/sign/proxy",
        json={"baseURL": "http://192.168.1.20:8000", "path": "cleanup"},
    )
    assert response.status_code == 422
    assert "cleanup" in response.json()["detail"]


def test_proxy_reads_status(client, monkeypatch):
    payload = {"certValid": True, "certName": "Test", "certDaysRemaining": 5, "installedApps": 3,
               "signedApps": 2, "pendingUpdates": 1, "certRevoked": False, "certExpiry": None,
               "certPPQLess": None, "storageFree": 1000}
    seen: list[httpx.Request] = []

    def handler(request):
        assert request.url.path == "/api/status"
        assert request.headers.get("X-VexSign-Token") == "s3cret"
        return httpx.Response(200, json=payload)

    monkeypatch.setattr(web_signer, "_make_client", mock_factory(handler, seen))
    response = client.post(
        "/api/tools/sign/proxy",
        json={"baseURL": "http://192.168.1.20:8000", "path": "status", "token": "s3cret"},
    )
    assert response.status_code == 200
    body = response.json()
    assert body["data"]["certDaysRemaining"] == 5
    assert body["path"] == "status"
    assert body["latencyMs"] >= 0
    assert len(seen) == 1


def test_proxy_sends_basic_auth(client, monkeypatch):
    def handler(request):
        assert request.headers.get("Authorization", "").startswith("Basic ")
        return httpx.Response(200, json=[])

    monkeypatch.setattr(web_signer, "_make_client", mock_factory(handler))
    response = client.post(
        "/api/tools/sign/proxy",
        json={
            "baseURL": "http://192.168.1.20:8000",
            "path": "library",
            "username": "vex",
            "password": "sign",
        },
    )
    assert response.status_code == 200
    assert response.json()["data"] == []


def test_proxy_passes_upstream_auth_failure(client, monkeypatch):
    def handler(request):
        return httpx.Response(401, text="Missing or wrong X-VexSign-Token.")

    monkeypatch.setattr(web_signer, "_make_client", mock_factory(handler))
    response = client.post("/api/tools/sign/proxy", json={"baseURL": "http://192.168.1.20:8000"})
    assert response.status_code == 401
    assert "X-VexSign-Token" in response.json()["detail"]


def test_proxy_reports_unreachable_phone(client, monkeypatch):
    def handler(request):
        raise httpx.ConnectError("no route", request=request)

    monkeypatch.setattr(web_signer, "_make_client", mock_factory(handler))
    response = client.post("/api/tools/sign/proxy", json={"baseURL": "http://192.168.1.99:8000"})
    assert response.status_code == 502
    assert "Could not reach" in response.json()["detail"]


def test_sign_streams_signed_ipa_back(client, monkeypatch):
    signed = b"PK\x03\x04signed-ipa-bytes"

    def handler(request):
        assert request.url.path == "/api/sign"
        assert request.method == "POST"
        assert request.headers["Content-Type"] == "application/octet-stream"
        assert request.headers["X-VexSign-Token"] == "tok"
        uploaded = request.read()
        assert uploaded == b"PK\x03\x04uploaded"
        return httpx.Response(200, content=signed)

    monkeypatch.setattr(web_signer, "_make_client", mock_factory(handler))
    response = client.post(
        "/api/tools/sign/sign",
        data={"baseURL": "http://192.168.1.20:8000", "token": "tok"},
        files={"file": ("My App.ipa", b"PK\x03\x04uploaded", "application/octet-stream")},
    )
    assert response.status_code == 200
    assert response.content == signed
    assert "Signed-My-App.ipa" in response.headers["content-disposition"]


def test_sign_reports_no_certificate(client, monkeypatch):
    def handler(request):
        return httpx.Response(412, text="No certificate available. Import one in Settings → Certificates.")

    monkeypatch.setattr(web_signer, "_make_client", mock_factory(handler))
    response = client.post(
        "/api/tools/sign/sign",
        data={"baseURL": "http://192.168.1.20:8000"},
        files={"file": ("app.ipa", b"bytes", "application/octet-stream")},
    )
    assert response.status_code == 412
    assert "No certificate available" in response.json()["detail"]


def test_signer_page_renders(client):
    response = client.get("/tools/signer")
    assert response.status_code == 200
    assert "Signer Console" in response.text
    assert "/api/tools/sign/sign" in response.text


# ---------------------------------------------------------------------------
# Repository decoder
# ---------------------------------------------------------------------------

ALTSTORE_FEED = json.dumps({
    "name": "Sample Store",
    "identifier": "com.example.store",
    "subtitle": "A sample",
    "apps": [
        {
            "name": "Alpha",
            "bundleIdentifier": "com.example.alpha",
            "developerName": "Example",
            "subtitle": "First",
            "version": "1.0",
            "versionDate": "2026-09-01T12:00:00Z",
            "iconURL": "https://example.com/a.png",
            "screenshotURLs": ["https://example.com/a1.png"],
            "downloadURL": "https://example.com/alpha.ipa",
            "size": 1048576,
        }
    ],
})

FLAT_FEED = json.dumps({
    "name": "Flat Store",
    "apps": [
        {
            "name": "Beta",
            "bundleID": "com.example.beta",
            "appDescription": "Flat schema spelling",
            "version": "2.1",
            "downloadUrl": "https://example.com/beta.ipa",
            "screenshots": "https://example.com/b1.png",
        }
    ],
})

XML_FEED = """<?xml version="1.0" encoding="UTF-8"?>
<apps>
  <app>
    <title>Gamma</title>
    <bundleid>com.example.gamma</bundleid>
    <version>3.0</version>
    <ipaurl>https://example.com/gamma.ipa</ipaurl>
    <screenshoturl>https://example.com/g1.png</screenshoturl>
    <description>Legacy appdata entry</description>
  </app>
</apps>
"""


def test_decode_altstore_feed(client):
    body = client.post("/api/tools/repo/decode", json={"payload": ALTSTORE_FEED}).json()
    assert body["format"] == "altstore"
    assert body["source"]["name"] == "Sample Store"
    assert body["stats"]["apps"] == 1
    assert body["stats"]["withDownloadURL"] == 1
    assert body["stats"]["totalBytes"] == 1048576
    assert body["apps"][0]["bundleIdentifier"] == "com.example.alpha"
    assert body["errorCount"] == 0


def test_decode_flat_schema_normalises_aliases(client):
    body = client.post("/api/tools/repo/decode", json={"payload": FLAT_FEED}).json()
    assert body["format"] == "flat"
    app = body["apps"][0]
    assert app["bundleIdentifier"] == "com.example.beta"
    assert app["downloadURL"] == "https://example.com/beta.ipa"
    assert app["localizedDescription"] == "Flat schema spelling"
    assert app["screenshotURLs"] == ["https://example.com/b1.png"]
    assert body["aliasesUsed"]["bundleID"] == 1
    assert body["aliasesUsed"]["downloadUrl"] == 1


def test_decode_bare_apps_json(client):
    payload = json.dumps([{"name": "Solo", "bundleIdentifier": "com.example.solo",
                           "version": "1.0", "downloadURL": "https://example.com/solo.ipa"}])
    body = client.post("/api/tools/repo/decode", json={"payload": payload}).json()
    assert body["format"] == "apps.json"
    assert body["stats"]["apps"] == 1


def test_decode_empty_but_valid_feed(client):
    """An empty AltStore feed is still an AltStore feed, not 'unknown'."""
    payload = json.dumps({"name": "Empty Store", "identifier": "com.example.empty", "apps": []})
    body = client.post("/api/tools/repo/decode", json={"payload": payload}).json()
    assert body["format"] == "altstore"
    assert body["stats"]["apps"] == 0
    assert any("no apps" in issue["message"] for issue in body["issues"])


def test_decode_sidestore_versions(client):
    payload = json.dumps({
        "name": "Versioned",
        "identifier": "com.example.versioned",
        "apps": [{
            "name": "Delta",
            "bundleIdentifier": "com.example.delta",
            "version": "1.1",
            "downloadURL": "https://example.com/delta.ipa",
            "versions": [
                {"version": "1.1", "downloadURL": "https://example.com/delta-1.1.ipa"},
                {"version": "1.0", "downloadURL": "https://example.com/delta-1.0.ipa"},
            ],
        }],
    })
    body = client.post("/api/tools/repo/decode", json={"payload": payload}).json()
    assert body["format"] == "altstore+versions"
    assert body["stats"]["inlineVersionEntries"] == 2


def test_decode_legacy_appdata_xml(client):
    body = client.post("/api/tools/repo/decode", json={"payload": XML_FEED}).json()
    assert body["format"] == "appdata-xml"
    assert body["stats"]["apps"] == 1
    app = body["apps"][0]
    assert app["name"] == "Gamma"
    assert app["bundleIdentifier"] == "com.example.gamma"
    assert app["downloadURL"] == "https://example.com/gamma.ipa"


def test_decode_reports_validator_errors(client):
    """The decoder reuses the Repository Creator's validator."""
    payload = json.dumps({"name": "Broken", "identifier": "com.example.broken", "apps": [
        {"name": "No download", "bundleIdentifier": "com.example.nodl", "version": "1.0"}
    ]})
    body = client.post("/api/tools/repo/decode", json={"payload": payload}).json()
    messages = [issue["message"] for issue in body["issues"]]
    assert any("no download URL" in message for message in messages)
    assert body["errorCount"] >= 1


def test_decode_rejects_malformed_json(client):
    response = client.post("/api/tools/repo/decode", json={"payload": "{not json"})
    assert response.status_code == 422
    assert "not valid JSON" in response.json()["detail"]


def test_decode_needs_input(client):
    response = client.post("/api/tools/repo/decode", json={})
    assert response.status_code == 422


def test_decode_fetches_url(client, monkeypatch):
    def handler(request):
        assert str(request.url) == "https://example.com/source.json"
        return httpx.Response(200, content=ALTSTORE_FEED.encode())

    monkeypatch.setattr(repo_decoder, "_make_client", mock_factory(handler))
    body = client.post("/api/tools/repo/decode", json={"source": "https://example.com/source.json"}).json()
    assert body["stats"]["apps"] == 1
    assert body["source"]["name"] == "Sample Store"


def test_decode_caps_oversized_feeds(client, monkeypatch):
    monkeypatch.setattr(repo_decoder, "MAX_FETCH_BYTES", 16)

    def handler(request):
        return httpx.Response(200, content=b"x" * 4096)

    monkeypatch.setattr(repo_decoder, "_make_client", mock_factory(handler))
    response = client.post("/api/tools/repo/decode", json={"source": "https://example.com/big.json"})
    assert response.status_code == 413


def test_decode_rejects_non_http_urls(client):
    response = client.post("/api/tools/repo/decode", json={"source": "file:///etc/passwd"})
    assert response.status_code == 422


def test_convert_changes_dialect(client):
    body = client.post(
        "/api/tools/repo/convert",
        json={"payload": FLAT_FEED, "format": "altstore"},
    ).json()
    assert body["fromFormat"] == "flat"
    assert body["format"] == "altstore"
    assert body["appCount"] == 1
    exported = json.loads(body["json"])
    assert exported["apps"][0]["bundleIdentifier"] == "com.example.beta"


def test_convert_rejects_unknown_format(client):
    response = client.post("/api/tools/repo/convert", json={"payload": ALTSTORE_FEED, "format": "zip"})
    assert response.status_code == 422


def test_repo_decoder_page_renders(client):
    response = client.get("/tools/repo-decoder")
    assert response.status_code == 200
    assert "Repository Decoder" in response.text
    assert "/api/tools/repo/decode" in response.text


# ---------------------------------------------------------------------------
# App installer
# ---------------------------------------------------------------------------

def test_manifest_requires_https(client):
    response = client.post(
        "/api/tools/install/manifest",
        json={"ipaURL": "http://example.com/app.ipa", "manifestURL": "https://example.com/m.plist"},
    )
    assert response.status_code == 422
    assert "https" in response.json()["detail"]


def test_manifest_builds_plist_and_link(client):
    import plistlib

    body = client.post(
        "/api/tools/install/manifest",
        json={
            "ipaURL": "https://example.com/app.ipa",
            "manifestURL": "https://example.com/manifest.plist",
            "name": "My App",
            "bundleIdentifier": "com.example.app",
            "version": "2.0",
            "size": 2048,
        },
    ).json()

    parsed = plistlib.loads(body["manifest"].encode())
    item = parsed["items"][0]
    assert item["metadata"]["bundle-identifier"] == "com.example.app"
    assert item["metadata"]["bundle-version"] == "2.0"
    assert item["metadata"]["kind"] == "software"
    assert item["assets"][0]["url"] == "https://example.com/app.ipa"

    link = body["installLink"]
    assert link.startswith("itms-services://?action=download-manifest&url=")
    assert "https%3A%2F%2Fexample.com%2Fmanifest.plist" in link
    assert body["errorCount"] == 0


def test_manifest_warns_without_bundle_id(client):
    body = client.post(
        "/api/tools/install/manifest",
        json={"ipaURL": "https://example.com/app.ipa", "manifestURL": "https://example.com/m.plist",
              "name": "No ID"},
    ).json()
    assert body["warningCount"] >= 1
    assert any("bundle identifier" in issue["message"] for issue in body["issues"])


def test_probe_fills_size_from_content_length(client, monkeypatch):
    def handler(request):
        assert request.method == "HEAD"
        return httpx.Response(200, headers={
            "content-type": "application/octet-stream",
            "content-length": "5242880",
        })

    monkeypatch.setattr(app_installer, "_make_client", mock_factory(handler))
    body = client.post(
        "/api/tools/install/manifest",
        json={
            "ipaURL": "https://example.com/app.ipa",
            "manifestURL": "https://example.com/m.plist",
            "name": "Probed",
            "bundleIdentifier": "com.example.probed",
            "version": "1.0",
            "probe": True,
        },
    ).json()

    assert body["size"] == 5242880
    assert body["probe"]["status"] == 200
    assert body["probe"]["contentLength"] == 5242880
    assert body["probe"]["ok"] is True


def test_probe_falls_back_to_get_when_head_is_refused(client, monkeypatch):
    def handler(request):
        if request.method == "HEAD":
            return httpx.Response(405)
        return httpx.Response(206, headers={"content-type": "application/octet-stream",
                                           "content-length": "1024"})

    monkeypatch.setattr(app_installer, "_make_client", mock_factory(handler))
    body = client.post("/api/tools/install/probe", json={"ipaURL": "https://example.com/app.ipa"}).json()
    assert body["method"] == "GET"
    assert body["status"] == 206
    assert body["ok"] is True


def test_probe_flags_missing_file(client, monkeypatch):
    def handler(request):
        return httpx.Response(404)

    monkeypatch.setattr(app_installer, "_make_client", mock_factory(handler))
    body = client.post("/api/tools/install/probe", json={"ipaURL": "https://example.com/gone.ipa"}).json()
    assert body["ok"] is False
    assert any("404" in issue["message"] for issue in body["issues"])


def test_probe_flags_html_content_type(client, monkeypatch):
    def handler(request):
        return httpx.Response(200, headers={"content-type": "text/html", "content-length": "512"})

    monkeypatch.setattr(app_installer, "_make_client", mock_factory(handler))
    body = client.post("/api/tools/install/probe", json={"ipaURL": "https://example.com/app.ipa"}).json()
    assert any(issue["severity"] == "warning" and "text/html" in issue["message"] for issue in body["issues"])


def test_probe_flags_cleartext_redirect(client, monkeypatch):
    def handler(request):
        if request.url.scheme == "https":
            return httpx.Response(302, headers={"location": "http://cdn.example.com/app.ipa"})
        return httpx.Response(200, headers={"content-type": "application/octet-stream",
                                           "content-length": "1024"})

    monkeypatch.setattr(app_installer, "_make_client", mock_factory(handler))
    body = client.post("/api/tools/install/probe", json={"ipaURL": "https://example.com/app.ipa"}).json()
    assert body["ok"] is False
    assert any("redirects to a non-https" in issue["message"] for issue in body["issues"])


def test_probe_reports_connection_failure(client, monkeypatch):
    def handler(request):
        raise httpx.ConnectError("refused", request=request)

    monkeypatch.setattr(app_installer, "_make_client", mock_factory(handler))
    body = client.post("/api/tools/install/probe", json={"ipaURL": "https://example.com/app.ipa"}).json()
    assert body["ok"] is False
    assert any(issue["severity"] == "error" for issue in body["issues"])


def test_app_installer_page_renders(client):
    response = client.get("/tools/app-installer")
    assert response.status_code == 200
    assert "App Installer" in response.text
    assert "/api/tools/install/manifest" in response.text


def test_hub_lists_all_six_tools(client):
    body = client.get("/tools").text
    for name in ("Signer Console", "Repository Creator", "Repository Decoder",
                 "App Installer", "Certificate Status Checker", "UDID Grabber"):
        assert name in body


# ---------------------------------------------------------------------------
# SSRF guard (repository decoder & app installer)
# ---------------------------------------------------------------------------

@pytest.mark.parametrize(
    "blocked_url",
    [
        "http://127.0.0.1:8080/feed.json",
        "http://169.254.169.254/latest/meta-data/",
        "http://10.0.0.5/feed.json",
        "http://192.168.1.10/feed.json",
        "http://100.64.0.1/feed.json",
        "http://[::1]/feed.json",
        "https://[::ffff:127.0.0.1]/feed.json",
        "http://localhost/feed.json",
        "https://metadata.google.internal/computeMetadata/v1/",
        "https://user:secret@example.com/feed.json",
    ],
)
def test_decoder_and_probe_block_non_public_targets(client, blocked_url):
    decode_resp = client.post("/api/tools/repo/decode", json={"source": blocked_url})
    assert decode_resp.status_code == 422

    probe_resp = client.post("/api/tools/install/probe", json={"ipaURL": blocked_url})
    assert probe_resp.status_code == 422


def test_decoder_blocks_redirect_to_metadata_before_connecting(client, monkeypatch):
    seen: list[str] = []

    def handler(request):
        seen.append(str(request.url))
        return httpx.Response(302, headers={"location": "http://169.254.169.254/latest/meta-data/"})

    monkeypatch.setattr(repo_decoder, "_make_client", mock_factory(handler))
    response = client.post("/api/tools/repo/decode", json={"source": "https://example.com/feed.json"})
    assert response.status_code == 422
    assert seen == ["https://example.com/feed.json"]


def test_probe_blocks_redirect_to_loopback_before_connecting(client, monkeypatch):
    seen: list[str] = []

    def handler(request):
        seen.append(str(request.url))
        return httpx.Response(302, headers={"location": "http://127.0.0.1:9000/internal"})

    monkeypatch.setattr(app_installer, "_make_client", mock_factory(handler))
    response = client.post("/api/tools/install/probe", json={"ipaURL": "https://example.com/app.ipa"})
    assert response.status_code == 422
    assert seen == ["https://example.com/app.ipa"]


def test_url_guard_blocks_dns_resolution_to_private_ip(client, monkeypatch):
    import ipaddress

    seen: list[str] = []

    def handler(request):
        seen.append(str(request.url))
        return httpx.Response(200, content=ALTSTORE_FEED.encode())

    monkeypatch.setattr(repo_decoder, "_make_client", mock_factory(handler))
    monkeypatch.setattr(url_guard, "_resolve_ips", lambda host, port: {ipaddress.ip_address("10.0.0.1")})
    response = client.post("/api/tools/repo/decode", json={"source": "https://rebind.example/feed.json"})
    assert response.status_code == 422
    assert "not a public IP" in response.json()["detail"]
    assert seen == []


# ---------------------------------------------------------------------------
# URL guard: malformed ports must be refused on both the fast path and the
# DNS-resolution path. Before the fix the fast path returned None and the DNS
# path raised an uncaught ValueError, producing HTTP 500 at public endpoints.
# ---------------------------------------------------------------------------

MALFORMED_PORT_URLS = (
    "https://example.com:99999/app.ipa",
    "https://example.com:65536/app.ipa",
    "https://example.com:-1/app.ipa",
    "https://example.com:abc/app.ipa",
    "https://example.com:+80/app.ipa",
    "https://example.com:0x50/app.ipa",
    "https://example.com:80:90/app.ipa",
    "https://[::1]:99999/app.ipa",
)

PORT_ZERO_URLS = (
    "https://example.com:0/app.ipa",
    "https://example.com:00000/app.ipa",
    "http://example.com:0/feed.json",
)


@pytest.mark.parametrize("url", MALFORMED_PORT_URLS + PORT_ZERO_URLS)
@pytest.mark.parametrize("resolve_dns", [False, True])
def test_url_guard_rejects_invalid_ports_on_every_path(url, resolve_dns, monkeypatch):
    def resolver(host, port):
        return {ipaddress.ip_address("93.184.216.34")}

    monkeypatch.setattr(url_guard, "_resolve_ips", resolver)
    assert url_guard.public_url_error(url, resolve_dns=resolve_dns) == "That address has an invalid port."


@pytest.mark.parametrize(
    "url",
    (
        "https://[::1:80/app.ipa",
        "https://[::1",
        "https://[::1]x/app.ipa",
    ),
)
def test_url_guard_rejects_malformed_ipv6_urls(url):
    assert url_guard.public_url_error(url, resolve_dns=False) == "That address is not a valid URL."


@pytest.mark.parametrize(
    "url,expected_port",
    (
        ("https://example.com/app.ipa", 443),
        ("http://example.com/app.ipa", 80),
        ("https://example.com:8443/app.ipa", 8443),
        ("http://example.com:8080/app.ipa", 8080),
        ("https://example.com:65535/app.ipa", 65535),
        ("https://example.com:/app.ipa", 443),
    ),
)
def test_url_guard_accepts_valid_ports_and_resolves_them(url, expected_port, monkeypatch):
    seen: list[int] = []

    def resolver(host, port):
        seen.append(port)
        return {ipaddress.ip_address("93.184.216.34")}

    monkeypatch.setattr(url_guard, "_resolve_ips", resolver)
    assert url_guard.public_url_error(url, resolve_dns=True) is None
    assert seen == [expected_port]


def test_url_guard_still_blocks_private_dns_with_explicit_port(monkeypatch):
    monkeypatch.setattr(
        url_guard, "_resolve_ips", lambda host, port: {ipaddress.ip_address("10.0.0.1")}
    )
    refusal = url_guard.public_url_error(
        "https://rebind.example:8443/feed.json", resolve_dns=True
    )
    assert refusal is not None
    assert "not a public IP" in refusal


def test_probe_rejects_initial_malformed_port(client):
    response = client.post(
        "/api/tools/install/probe",
        json={"ipaURL": "https://example.com:99999/app.ipa"},
    )
    assert response.status_code == 422
    assert "invalid port" in response.json()["detail"]


def test_decoder_rejects_initial_malformed_port(client):
    response = client.post(
        "/api/tools/repo/decode",
        json={"source": "https://example.com:99999/feed.json"},
    )
    assert response.status_code == 422
    assert "invalid port" in response.json()["detail"]


def test_probe_blocks_redirect_with_malformed_port(client, monkeypatch):
    seen: list[str] = []

    def handler(request):
        seen.append(str(request.url))
        return httpx.Response(
            302, headers={"location": "https://example.com:99999/app.ipa"}
        )

    monkeypatch.setattr(app_installer, "_make_client", mock_factory(handler))
    response = client.post(
        "/api/tools/install/probe",
        json={"ipaURL": "https://example.com/app.ipa"},
    )
    assert response.status_code == 422
    assert "invalid port" in response.json()["detail"]
    assert seen == ["https://example.com/app.ipa"]


def test_decoder_blocks_redirect_with_malformed_port(client, monkeypatch):
    seen: list[str] = []

    def handler(request):
        seen.append(str(request.url))
        return httpx.Response(
            302, headers={"location": "https://example.com:99999/feed.json"}
        )

    monkeypatch.setattr(repo_decoder, "_make_client", mock_factory(handler))
    response = client.post(
        "/api/tools/repo/decode",
        json={"source": "https://example.com/feed.json"},
    )
    assert response.status_code == 422
    assert "invalid port" in response.json()["detail"]
    assert seen == ["https://example.com/feed.json"]
