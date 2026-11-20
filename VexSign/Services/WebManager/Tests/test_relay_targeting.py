"""Relay targeting rules in web_signer.py.

The signer console relays to the phone's Web Manager, so the guard has to answer
three questions and used to answer none of them:

* is the address a LAN peer at all (cloud metadata and link-local are not)?
* can the caller put an arbitrary path on the wire by smuggling it through the
  address's query string?
* does a redirect hop get the same scrutiny as the first request?

Run from `VexSign/Services/WebManager/API/`:

    python -m pytest ../Tests/ -q

Every outbound call goes through an `httpx.MockTransport`; nothing here touches
the network.
"""

from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path

import httpx
import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "API"))

_TMP = tempfile.mkdtemp(prefix="vexsign-relay-test-")
os.environ.setdefault("VEXSIGN_DB", os.path.join(_TMP, "vexsign.db"))
os.environ.setdefault("REPO_STORE_DIR", os.path.join(_TMP, "store"))
os.environ.pop("VEXSIGN_ALLOW_PUBLIC_TARGETS", None)
os.environ.pop("VEXSIGN_RELAY_TOKEN", None)

import main  # noqa: E402
import web_signer  # noqa: E402


@pytest.fixture
def client():
    with TestClient(main.app) as test_client:
        yield test_client


def mock_factory(handler, seen: list[httpx.Request] | None = None):
    """Swap the module's client factory for a MockTransport-backed one.

    `follow_redirects=True` is deliberate: the relay must not depend on the
    transport declining to follow hops. It passes `follow_redirects=False` per
    request, which overrides this.
    """

    def factory():
        def respond(request: httpx.Request):
            if seen is not None:
                seen.append(request)
            return handler(request)

        return httpx.Client(transport=httpx.MockTransport(respond), follow_redirects=True)

    return factory


# ---------------------------------------------------------------------------
# Address class
# ---------------------------------------------------------------------------

@pytest.mark.parametrize(
    "url",
    [
        "http://169.254.169.254",          # cloud metadata (IMDSv1)
        "http://169.254.169.254/latest/meta-data/",
        "http://[fe80::1]:8000",           # IPv6 link-local
        "http://224.0.0.1",                # multicast
        "http://0.0.0.0",                  # unspecified
    ],
)
def test_guard_refuses_link_local_and_metadata(url):
    refusal = web_signer.target_guard_error(url)
    assert refusal is not None, f"{url} must not be reachable through the relay"
    assert "private" in refusal


def test_guard_still_allows_lan_and_tailnet_peers():
    assert web_signer.target_guard_error("http://192.168.1.20:8000") is None
    assert web_signer.target_guard_error("http://10.0.0.7") is None
    assert web_signer.target_guard_error("http://100.64.0.1:8000") is None


def test_loopback_is_treated_the_same_in_both_families():
    """`::1` is also inside IPv6's reserved `::/8`, so the order of the checks matters."""
    assert web_signer.target_guard_error("http://127.0.0.1:8000") is None
    assert web_signer.target_guard_error("http://[::1]:8000") is None


@pytest.mark.parametrize(
    "base",
    ["http://[::1", "http://host:99999", "http:///nohost"],
)
def test_malformed_addresses_are_refused_not_raised(client, base):
    """A user-supplied string must never surface as a 500 from the relay."""
    assert web_signer.target_guard_error(base) is not None
    assert web_signer.target_url(base, "status")[0] is None

    response = client.post(
        "/api/Tools/sign/proxy",
        json={"baseURL": base, "path": "status"},
    )
    assert response.status_code == 422, response.text
    assert response.json()["detail"]


# ---------------------------------------------------------------------------
# Address shape: the endpoint, not the caller, decides the path
# ---------------------------------------------------------------------------

def test_target_url_cannot_smuggle_a_path_through_a_query_string():
    url, refusal = web_signer.target_url(
        "http://169.254.169.254/latest/meta-data/iam/security-credentials/role?",
        "status",
    )
    assert url is None
    assert refusal and "query" in refusal


@pytest.mark.parametrize(
    "base",
    [
        "http://192.168.1.20:8000/?x=",
        "http://192.168.1.20:8000/#frag",
        "http://user:pass@192.168.1.20:8000",
        "http://192.168.1.20:8000\r\nX-Injected: 1",
    ],
)
def test_target_url_refuses_addresses_carrying_more_than_an_authority(base):
    url, refusal = web_signer.target_url(base, "status")
    assert url is None
    assert refusal


def test_target_url_appends_the_endpoint_to_the_base_path():
    url, refusal = web_signer.target_url("http://192.168.1.20:8000/", "status")
    assert refusal is None
    assert url == "http://192.168.1.20:8000/api/status"

    url, _ = web_signer.target_url("https://phone.example.ts.net:8443/", "library")
    assert url == "https://phone.example.ts.net:8443/api/library"


def test_proxy_rejects_a_query_string_address(client):
    response = client.post(
        "/api/Tools/sign/proxy",
        json={"baseURL": "http://192.168.1.20:8000/?x=", "path": "status"},
    )
    assert response.status_code == 422
    assert "query" in response.json()["detail"]


# ---------------------------------------------------------------------------
# Redirects are re-validated hop by hop
# ---------------------------------------------------------------------------

def test_proxy_refuses_a_redirect_towards_a_blocked_target(client, monkeypatch):
    def handler(request):
        return httpx.Response(302, headers={"location": "http://169.254.169.254/latest/meta-data/"})

    monkeypatch.setattr(web_signer, "_make_client", mock_factory(handler))
    response = client.post(
        "/api/Tools/sign/proxy",
        json={"baseURL": "http://192.168.1.20:8000", "path": "status"},
    )
    assert response.status_code == 422
    assert "169.254.169.254" in response.json()["detail"]


def test_proxy_follows_a_redirect_between_allowed_targets(client, monkeypatch):
    seen: list[httpx.Request] = []

    def handler(request):
        if request.url.path == "/api/status" and str(request.url.host) == "192.168.1.20":
            return httpx.Response(307, headers={"location": "http://192.168.1.21:8000/api/status"})
        return httpx.Response(200, json={"certValid": True})

    monkeypatch.setattr(web_signer, "_make_client", mock_factory(handler, seen))
    response = client.post(
        "/api/Tools/sign/proxy",
        json={"baseURL": "http://192.168.1.20:8000", "path": "status"},
    )
    assert response.status_code == 200, response.text
    assert [str(request.url.host) for request in seen] == ["192.168.1.20", "192.168.1.21"]


def test_proxy_gives_up_on_a_redirect_loop(client, monkeypatch):
    def handler(request):
        return httpx.Response(302, headers={"location": "/api/status"})

    monkeypatch.setattr(web_signer, "_make_client", mock_factory(handler))
    response = client.post(
        "/api/Tools/sign/proxy",
        json={"baseURL": "http://192.168.1.20:8000", "path": "status"},
    )
    assert response.status_code == 422
    assert "Too many redirects" in response.json()["detail"]


def test_sign_relay_does_not_follow_a_redirect(client, monkeypatch):
    """A streamed upload cannot be replayed against a second host."""
    def handler(request):
        return httpx.Response(302, headers={"location": "http://10.0.0.9:8000/api/sign"})

    monkeypatch.setattr(web_signer, "_make_client", mock_factory(handler))
    response = client.post(
        "/api/Tools/sign/sign",
        files={"file": ("app.ipa", b"PK\x03\x04payload", "application/octet-stream")},
        data={"baseURL": "http://192.168.1.20:8000"},
    )
    assert response.status_code == 502
    assert "redirect" in response.json()["detail"]


# ---------------------------------------------------------------------------
# Optional shared secret for a relay that is not on a LAN
# ---------------------------------------------------------------------------

def test_relay_token_absent_keeps_the_tool_public(client, monkeypatch):
    def handler(request):
        return httpx.Response(200, json={"certValid": True})

    monkeypatch.setattr(web_signer, "_make_client", mock_factory(handler))
    response = client.post(
        "/api/Tools/sign/proxy",
        json={"baseURL": "http://192.168.1.20:8000", "path": "status"},
    )
    assert response.status_code == 200


def test_relay_token_is_required_when_configured(client, monkeypatch):
    monkeypatch.setenv("VEXSIGN_RELAY_TOKEN", "relay-s3cret")
    response = client.post(
        "/api/Tools/sign/proxy",
        json={"baseURL": "http://192.168.1.20:8000", "path": "status"},
    )
    assert response.status_code == 403
    assert "X-Relay-Token" in response.json()["detail"]


def test_relay_token_is_accepted_when_configured(client, monkeypatch):
    monkeypatch.setenv("VEXSIGN_RELAY_TOKEN", "relay-s3cret")

    def handler(request):
        return httpx.Response(200, json={"certValid": True})

    monkeypatch.setattr(web_signer, "_make_client", mock_factory(handler))
    response = client.post(
        "/api/Tools/sign/proxy",
        json={"baseURL": "http://192.168.1.20:8000", "path": "status"},
        headers={"X-Relay-Token": "relay-s3cret"},
    )
    assert response.status_code == 200


def test_relay_token_rejects_a_wrong_value(client, monkeypatch):
    monkeypatch.setenv("VEXSIGN_RELAY_TOKEN", "relay-s3cret")
    response = client.post(
        "/api/Tools/sign/proxy",
        json={"baseURL": "http://192.168.1.20:8000", "path": "status"},
        headers={"X-Relay-Token": "wrong"},
    )
    assert response.status_code == 403
