"""Public-URL derivation in request_base.py.

The base URL is interpolated into the feed URLs the app is told to fetch as a
premium source, so the header that produces it decides where a client goes. Two
properties are covered here: a malformed header can never produce a URL that
parses as something else, and an operator can pin the allowlist.

Run from `VexSign/Services/WebManager/API/`:

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

_TMP = tempfile.mkdtemp(prefix="vexsign-baseurl-test-")
os.environ.setdefault("VEXSIGN_DB", os.path.join(_TMP, "vexsign.db"))
os.environ.setdefault("REPO_STORE_DIR", os.path.join(_TMP, "store"))
os.environ.pop("PUBLIC_BASE_URL", None)
os.environ.pop("VEXSIGN_TRUSTED_HOSTS", None)

import main  # noqa: E402
import request_base  # noqa: E402


@pytest.fixture
def client():
    with TestClient(main.app) as test_client:
        yield test_client


@pytest.fixture(autouse=True)
def _clear_base_url_env(monkeypatch):
    monkeypatch.delenv("PUBLIC_BASE_URL", raising=False)
    monkeypatch.delenv("VEXSIGN_TRUSTED_HOSTS", raising=False)


# ---------------------------------------------------------------------------
# Host token validation
# ---------------------------------------------------------------------------

@pytest.mark.parametrize(
    "value",
    [
        "example.com",
        "example.com:8443",
        "192.168.1.20:8000",
        "[::1]:8000",
        "vexsign-premium.onrender.com",
    ],
)
def test_safe_host_accepts_authorities(value):
    assert request_base.safe_host(value) == value


@pytest.mark.parametrize(
    "value",
    [
        "",
        None,
        "evil.com\r\nX-Injected: 1",
        "evil.com/path",
        "user:pass@evil.com",
        "evil.com\"><script>",
        "evil.com evil.com",
        "[::1",
        "a" * 300,
    ],
)
def test_safe_host_rejects_anything_else(value):
    assert request_base.safe_host(value) is None


def test_malformed_forwarded_host_falls_back_instead_of_leaking(client):
    """A rejected forwarded host falls back to the request's own Host, which is
    also validated — never to the garbage the caller supplied."""
    response = client.get(
        "/repo/source.json",
        headers={"X-Forwarded-Host": "evil.com\r\nX-Injected: 1", "X-Forwarded-Proto": "https"},
    )
    assert response.status_code == 200
    body = response.text
    assert "evil.com" not in body
    assert "https://testserver" in body  # TestClient's own (valid) Host header


def test_non_http_scheme_is_not_interpolated(client):
    response = client.get(
        "/repo/source.json",
        headers={"X-Forwarded-Host": "vexsign.example.com", "X-Forwarded-Proto": "javascript"},
    )
    assert response.status_code == 200
    assert "javascript:" not in response.text


@pytest.mark.parametrize("proto", ["https", "HTTPS", "https, http"])
def test_forwarded_proto_is_normalised(client, proto):
    response = client.get(
        "/repo/source.json",
        headers={"X-Forwarded-Host": "vexsign.example.com", "X-Forwarded-Proto": proto},
    )
    assert response.status_code == 200
    assert "https://vexsign.example.com" in response.text


def test_public_base_url_wins_over_headers(client, monkeypatch):
    monkeypatch.setenv("PUBLIC_BASE_URL", "https://feeds.example.com/")
    response = client.get("/repo/source.json", headers={"Host": "spoofed.example.net"})
    assert response.status_code == 200
    assert "https://feeds.example.com" in response.text
    assert "spoofed.example.net" not in response.text


# ---------------------------------------------------------------------------
# Allowlist
# ---------------------------------------------------------------------------

def test_trusted_hosts_accepts_an_exact_match(client, monkeypatch):
    monkeypatch.setenv("VEXSIGN_TRUSTED_HOSTS", "vexsign.example.com")
    response = client.get("/repo/source.json", headers={"Host": "vexsign.example.com"})
    assert response.status_code == 200
    assert "https://vexsign.example.com" in response.text or "http://vexsign.example.com" in response.text


def test_trusted_hosts_rejects_an_unlisted_host(client, monkeypatch):
    monkeypatch.setenv("VEXSIGN_TRUSTED_HOSTS", "vexsign.example.com")
    response = client.get("/repo/source.json", headers={"Host": "spoofed.example.net"})
    assert response.status_code == 400
    assert "Untrusted Host" in response.json()["detail"]


def test_trusted_hosts_supports_a_wildcard(client, monkeypatch):
    monkeypatch.setenv("VEXSIGN_TRUSTED_HOSTS", "*.example.com")
    assert client.get("/repo/source.json", headers={"Host": "a.example.com"}).status_code == 200
    assert client.get("/repo/source.json", headers={"Host": "example.com"}).status_code == 400
    assert client.get("/repo/source.json", headers={"Host": "a.example.net"}).status_code == 400


def test_trusted_hosts_ignores_a_port_in_the_entry(client, monkeypatch):
    monkeypatch.setenv("VEXSIGN_TRUSTED_HOSTS", "vexsign.example.com:8443")
    response = client.get("/repo/source.json", headers={"Host": "vexsign.example.com:8443"})
    assert response.status_code == 200


def test_trusted_hosts_unset_keeps_the_previous_behaviour(client):
    """An existing reverse proxy must not break on upgrade."""
    response = client.get("/repo/source.json", headers={"Host": "anything.example.net"})
    assert response.status_code == 200


def test_trusted_hosts_is_parsed_leniently(monkeypatch):
    monkeypatch.setenv("VEXSIGN_TRUSTED_HOSTS", " a.example.com , ,B.Example.com ,")
    assert request_base.trusted_hosts() == ["a.example.com", "b.example.com"]
