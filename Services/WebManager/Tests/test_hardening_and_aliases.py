"""Regression tests for WebManager hardening, TLS pinning, streaming probes, and route aliases."""
from __future__ import annotations

import hashlib
import io
import ipaddress
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

import httpcore
import httpx
import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "API"))

_TMP = tempfile.mkdtemp(prefix="vexsign-hardening-test-")
os.environ.setdefault("VEXSIGN_DB", os.path.join(_TMP, "vexsign.db"))
os.environ.setdefault("REPO_STORE_DIR", os.path.join(_TMP, "store"))

import app_installer  # noqa: E402
import db  # noqa: E402
import main  # noqa: E402
import rate_limit  # noqa: E402
import repo_store  # noqa: E402
import udid_grabber  # noqa: E402
import url_guard  # noqa: E402
import web_chrome  # noqa: E402
import web_signer  # noqa: E402


@pytest.fixture
def client():
    with TestClient(main.app) as test_client:
        yield test_client


# ---------------------------------------------------------------------------
# 1. TLS leaf SHA-256 pinning & Web Signer HTTPS defaults / redirect safety
# ---------------------------------------------------------------------------


class _FakeSSLObject:
    def __init__(self, der_bytes: bytes):
        self._der = der_bytes

    def getpeercert(self, binary_form: bool = False):
        return self._der if binary_form else {}

    def selected_alpn_protocol(self) -> str:
        return "http/1.1"


class _FakeTLSStream(httpcore.NetworkStream):
    def __init__(self, der_bytes: bytes):
        self.der_bytes = der_bytes
        self.writes: list[bytes] = []
        self.closed = False
        self._response = b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 18\r\n\r\n{\"certValid\":true}"

    def read(self, max_bytes: int, timeout: float | None = None) -> bytes:
        chunk, self._response = self._response[:max_bytes], self._response[max_bytes:]
        return chunk

    def write(self, buffer: bytes, timeout: float | None = None) -> None:
        self.writes.append(buffer)

    def close(self) -> None:
        self.closed = True

    def start_tls(self, ssl_context, server_hostname=None, timeout=None):
        return self

    def get_extra_info(self, info: str):
        if info == "ssl_object":
            return _FakeSSLObject(self.der_bytes)
        return None


def test_signer_tls_fingerprint_pin_accepts_match_and_rejects_mismatch_before_write(monkeypatch):
    cert_der = b"fake-self-signed-phone-leaf-der-bytes"
    good_pin = hashlib.sha256(cert_der).hexdigest()
    bad_pin = "0" * 64

    monkeypatch.setattr(url_guard, "_resolve_ips", lambda host, port: {ipaddress.ip_address("192.168.1.20")})

    stream_ok = _FakeTLSStream(cert_der)
    monkeypatch.setattr(httpcore.SyncBackend, "connect_tcp", lambda *a, **kw: stream_ok)
    with web_signer._make_client(tls_cert_sha256=f"SHA256:{good_pin.upper()}") as https_client:
        res = https_client.get("https://192.168.1.20:8080/api/status", headers={"X-VexSign-Token": "secret"})
    assert res.status_code == 200
    assert b"X-VexSign-Token: secret" in b"".join(stream_ok.writes)

    stream_bad = _FakeTLSStream(cert_der)
    monkeypatch.setattr(httpcore.SyncBackend, "connect_tcp", lambda *a, **kw: stream_bad)
    with web_signer._make_client(tls_cert_sha256=bad_pin) as https_client:
        with pytest.raises(httpx.ConnectError, match="SHA-256 mismatch"):
            https_client.get("https://192.168.1.20:8080/api/status", headers={"X-VexSign-Token": "secret"})
    assert stream_bad.writes == []
    assert stream_bad.closed is True


def test_signer_validates_tls_trust_inputs_and_defaults_to_https_8080(client):
    page_html = client.get("/Tools/signer").text
    assert 'placeholder="https://192.168.1.20:8080"' in page_html

    bad_pin = client.post(
        "/api/Tools/sign/proxy",
        json={"baseURL": "https://192.168.1.20:8080", "path": "status", "tlsCertSha256": "not-hex"},
    )
    assert bad_pin.status_code == 422
    assert "64-character" in bad_pin.json()["detail"]

    bad_pem = client.post(
        "/api/Tools/sign/proxy",
        json={"baseURL": "https://192.168.1.20:8080", "path": "status", "caCertPem": "not-a-pem"},
    )
    assert bad_pem.status_code == 422
    assert "PEM" in bad_pem.json()["detail"]


def test_signer_malformed_redirect_location_never_escapes_as_500(client, monkeypatch):
    def empty_host_factory(**kwargs):
        return httpx.Client(
            transport=httpx.MockTransport(
                lambda _req: httpx.Response(302, headers={"location": "//"})
            )
        )

    monkeypatch.setattr(web_signer, "_make_client", empty_host_factory)
    res_empty_host = client.post(
        "/api/Tools/sign/proxy",
        json={"baseURL": "https://192.168.1.20:8080", "path": "status"},
    )
    assert res_empty_host.status_code == 422

    def bad_ipv6_factory(**kwargs):
        return httpx.Client(
            transport=httpx.MockTransport(
                lambda _req: httpx.Response(302, headers={"location": "http://[::1"})
            )
        )

    monkeypatch.setattr(web_signer, "_make_client", bad_ipv6_factory)
    res_bad_ipv6 = client.post(
        "/api/Tools/sign/proxy",
        json={"baseURL": "https://192.168.1.20:8080", "path": "status"},
    )
    assert res_bad_ipv6.status_code in (422, 502)


# ---------------------------------------------------------------------------
# 2. App Installer streaming probe & 206 Content-Range total size
# ---------------------------------------------------------------------------


def test_probe_streams_bounded_bytes_and_parses_content_range_total(monkeypatch):
    chunks_emitted = 0

    class _InfiniteBody(httpx.SyncByteStream):
        def __iter__(self):
            nonlocal chunks_emitted
            for _ in range(1000):
                chunks_emitted += 1
                yield b"X" * 4096

    def handler(request: httpx.Request) -> httpx.Response:
        if request.method == "HEAD":
            return httpx.Response(405)
        return httpx.Response(
            206,
            headers={
                "content-type": "application/octet-stream",
                "content-length": "1024",
                "content-range": "bytes 0-1023/98765432",
            },
            stream=_InfiniteBody(),
        )

    monkeypatch.setattr(
        app_installer,
        "_make_client",
        lambda: httpx.Client(transport=httpx.MockTransport(handler)),
    )
    report = app_installer.probe_url("https://example.com/huge.ipa")
    assert report["ok"] is True
    assert report["contentLength"] == 98765432
    assert chunks_emitted <= 2


# ---------------------------------------------------------------------------
# 3. Spoof-resistant X-Forwarded-For rate limiting & Render blueprint
# ---------------------------------------------------------------------------


def test_forwarded_for_selects_rightmost_untrusted_ip_against_spoofing(monkeypatch):
    monkeypatch.setenv("VEXSIGN_TRUST_FORWARDED_FOR", "1")
    monkeypatch.delenv("VEXSIGN_TRUSTED_PROXY_HOPS", raising=False)

    class _Peer:
        host = "10.0.0.5"

    class _SpoofedRequest:
        headers = {"x-forwarded-for": "198.51.100.99, 203.0.113.42, 10.0.0.5"}
        client = _Peer()

    assert rate_limit.client_key(_SpoofedRequest()) == "203.0.113.42"

    monkeypatch.setenv("VEXSIGN_TRUSTED_PROXY_HOPS", "2")

    class _TwoProxyRequest:
        headers = {"x-forwarded-for": "198.51.100.99, 203.0.113.42, 198.51.100.1"}
        client = _Peer()

    assert rate_limit.client_key(_TwoProxyRequest()) == "203.0.113.42"


def test_render_blueprint_enables_forwarded_for():
    blueprint = (Path(__file__).resolve().parents[1] / "Configuration" / "render.yaml").read_text(encoding="utf-8")
    assert "VEXSIGN_TRUST_FORWARDED_FOR" in blueprint


# ---------------------------------------------------------------------------
# 4. UDID Grabber: 413 body cap, downloaded session eviction protection, HTML code tag, rate limit
# ---------------------------------------------------------------------------


def test_udid_callback_rejects_oversized_body_with_413(client):
    token = udid_grabber.create_session()
    oversized = b"<?xml version='1.0'?><plist><dict>" + (b"A" * (udid_grabber.MAX_CALLBACK_BYTES + 1024))
    res = client.post(f"/api/udid/callback?token={token}", content=oversized)
    assert res.status_code == 413


def test_udid_downloaded_session_survives_unclaimed_flood(client, monkeypatch):
    with udid_grabber._lock:
        udid_grabber._sessions.clear()
    monkeypatch.setattr(udid_grabber, "MAX_SESSIONS", 3)

    claimed = udid_grabber.create_session()
    assert client.get(f"/api/Tools/udid/profile?token={claimed}").status_code == 200

    for _ in range(10):
        udid_grabber.create_session()

    assert udid_grabber.get_session(claimed) is not None


def test_udid_page_is_rate_limited_per_client(client):
    rate_limit.current_udid().limit = 2
    assert client.get("/Tools/udid").status_code == 200
    assert client.get("/Tools/udid").status_code == 200
    assert client.get("/Tools/udid").status_code == 429


@pytest.mark.skipif(shutil.which("node") is None, reason="node is not installed")
def test_udid_row_renders_real_code_tag_while_escaping_udid(client):
    html_text = client.get("/Tools/udid").text
    assert "<code>${esc(data.device.DEVICE_UDID)}</code>" in html_text
    script = (
        web_chrome.SHARED_JS
        + "\nconst udid = '<img src=x onerror=alert(1)>';"
        + "\nconsole.log(`<tr><th>UDID</th><td><code>${esc(udid)}</code></td></tr>`);"
    )
    out = subprocess.run(["node", "-e", script], capture_output=True, text=True, check=True).stdout.strip()
    assert "<td><code>&lt;img" in out
    assert "&lt;code&gt;" not in out


# ---------------------------------------------------------------------------
# 5. repo_store Info.plist zip-bomb cap & db index
# ---------------------------------------------------------------------------


def test_repo_store_rejects_oversized_info_plist(tmp_path, monkeypatch):
    monkeypatch.setattr(repo_store, "MAX_INFO_PLIST_BYTES", 1024)
    ipa_path = tmp_path / "bomb.ipa"
    big_plist = plistlib.dumps({
        "CFBundleIdentifier": "com.example.bomb",
        "CFBundleDisplayName": "Bomb",
        "CFBundleShortVersionString": "1.0",
        "Padding": "P" * 4096,
    })
    with zipfile.ZipFile(ipa_path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("Payload/Bomb.app/Info.plist", big_plist)

    with pytest.raises(repo_store.RepoError, match="size limit"):
        repo_store.read_ipa_metadata(ipa_path)


def test_db_creates_device_uuid_index(tmp_path, monkeypatch):
    db_file = tmp_path / "indexed.db"
    monkeypatch.setattr(db, "DB_PATH", str(db_file))
    with db.connection() as conn:
        indexes = {
            row["name"]
            for row in conn.execute("PRAGMA index_list('keys')").fetchall()
        }
    assert "idx_keys_device_uuid" in indexes


# ---------------------------------------------------------------------------
# 6. Lowercase /tools/* and /api/tools/* aliases
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "path",
    [
        "/Tools",
        "/tools/signer",
        "/tools/repo-creator",
        "/tools/repo-decoder",
        "/tools/app-installer",
        "/tools/cert-check",
        "/tools/udid",
        "/api/tools/cert/revoked-list",
    ],
)
def test_lowercase_tool_routes_are_mounted(client, path):
    res = client.get(path)
    assert res.status_code == 200, path


def test_bare_host_port_defaults_to_https_in_web_signer():
    assert web_signer.target_guard_error("192.168.1.20:8080") is None
    url, err = web_signer.target_url("192.168.1.20:8080", "status")
    assert err is None
    assert url == "https://192.168.1.20:8080/api/status"

