"""The public fetch transport binds validated DNS answers to the TCP connection."""
from __future__ import annotations

import ipaddress
import sys
from pathlib import Path

import httpcore
import httpx
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "API"))
import repo_decoder  # noqa: E402
import url_guard  # noqa: E402
import web_signer  # noqa: E402


class FakeStream(httpcore.NetworkStream):
    def __init__(self):
        self.writes = []
        self.sni = None
        self.response = b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"

    def read(self, max_bytes, timeout=None):
        data, self.response = self.response[:max_bytes], self.response[max_bytes:]
        return data

    def write(self, buffer, timeout=None):
        self.writes.append(buffer)

    def close(self):
        pass

    def start_tls(self, ssl_context, server_hostname=None, timeout=None):
        self.sni = server_hostname
        return self

    def get_extra_info(self, info):
        return None


def test_validated_address_is_connected_but_tls_and_host_keep_the_hostname(monkeypatch):
    stream = FakeStream()
    dialed = []
    monkeypatch.setattr(url_guard, "_resolve_ips", lambda host, port: {ipaddress.ip_address("8.8.8.8")})
    def connect(_self, host, port, timeout=None, local_address=None, socket_options=None):
        dialed.append((host, port))
        return stream
    monkeypatch.setattr(httpcore.SyncBackend, "connect_tcp", connect)
    with url_guard.public_http_client(timeout=5) as client:
        response = client.get("https://example.com/source.json")
    assert response.status_code == 200
    assert dialed == [("8.8.8.8", 443)]
    assert stream.sni == "example.com"
    assert b"Host: example.com" in b"".join(stream.writes)


def test_connection_refuses_private_or_mixed_answers(monkeypatch):
    dialed = []
    monkeypatch.setattr(httpcore.SyncBackend, "connect_tcp", lambda *args, **kwargs: dialed.append(args))
    for addresses in [
        {ipaddress.ip_address("127.0.0.1")},
        {ipaddress.ip_address("8.8.8.8"), ipaddress.ip_address("10.0.0.1")},
        {ipaddress.ip_address("::ffff:169.254.169.254")},
    ]:
        monkeypatch.setattr(url_guard, "_resolve_ips", lambda host, port: addresses)
        with url_guard.public_http_client(timeout=5) as client:
            with pytest.raises(httpx.ConnectError):
                client.get("http://example.com/")
    assert dialed == []


def test_rebinding_between_validation_and_connect_never_dials_private_ip(monkeypatch):
    answers = iter([{ipaddress.ip_address("8.8.8.8")}, {ipaddress.ip_address("127.0.0.1")}])
    monkeypatch.setattr(url_guard, "_resolve_ips", lambda host, port: next(answers))
    dialed = []
    monkeypatch.setattr(httpcore.SyncBackend, "connect_tcp", lambda *args, **kwargs: dialed.append(args))
    from fastapi import HTTPException
    with pytest.raises(HTTPException) as error:
        repo_decoder.fetch_text("http://example.com/feed.json")
    assert error.value.status_code == 502
    assert dialed == []


def test_transport_ignores_environment_proxies(monkeypatch):
    monkeypatch.setenv("HTTP_PROXY", "http://127.0.0.1:8080")
    with url_guard.public_http_client(timeout=5) as client:
        assert client.trust_env is False
        assert isinstance(client._transport._pool._network_backend, url_guard.CheckedNetworkBackend)


def test_relay_rebinding_to_metadata_is_refused_by_connector(monkeypatch):
    answers = iter([{ipaddress.ip_address("192.168.1.10")}, {ipaddress.ip_address("169.254.169.254")}])
    # Validation uses socket.getaddrinfo; the connector performs its own final
    # checked resolution. Simulate a change after the validation answer.
    monkeypatch.setattr(web_signer.socket, "getaddrinfo", lambda host, port: [
        (2, 1, 6, "", (str(next(answers).pop()), port))
    ])
    monkeypatch.setattr(url_guard, "_resolve_ips", lambda host, port: next(answers))
    dialed = []
    monkeypatch.setattr(httpcore.SyncBackend, "connect_tcp", lambda *args, **kwargs: dialed.append(args))
    assert web_signer.target_guard_error("http://phone.example:8000") is None
    with web_signer._make_client() as client:
        with pytest.raises(httpx.ConnectError):
            client.get("http://phone.example:8000/api/status")
    assert dialed == []


def test_relay_cross_origin_redirect_does_not_forward_credentials():
    seen = []
    def reply(request):
        seen.append(request)
        return httpx.Response(302, headers={"location": "http://127.0.0.2/api/status"})
    with httpx.Client(transport=httpx.MockTransport(reply)) as client:
        with pytest.raises(web_signer.UnsafeTarget, match="different origin"):
            web_signer._request_with_safe_redirects(client, "GET", "http://127.0.0.1/api/status", {"X-VexSign-Token": "secret"})
    assert len(seen) == 1


# ---------------------------------------------------------------------------
# The hook is private, so it is verified rather than assumed. A rename that
# leaves the assignment succeeding while the pool ignores it would remove SSRF
# protection with no error anywhere — these prove that fails closed instead.
# ---------------------------------------------------------------------------


def test_client_refuses_to_build_when_the_backend_attribute_disappears(monkeypatch):
    class _Pool:
        pass

    class _Transport:
        def __init__(self, *args, **kwargs):
            self._pool = _Pool()

    monkeypatch.setattr(url_guard.httpx, "HTTPTransport", _Transport)
    with pytest.raises(RuntimeError, match="network-backend hook"):
        url_guard.public_http_client(timeout=5)


def test_client_refuses_to_build_when_the_pool_disappears(monkeypatch):
    class _Transport:
        def __init__(self, *args, **kwargs):
            pass

    monkeypatch.setattr(url_guard.httpx, "HTTPTransport", _Transport)
    with pytest.raises(RuntimeError, match="network-backend hook"):
        url_guard.public_http_client(timeout=5)


def test_client_refuses_to_build_when_connect_tcp_is_renamed(monkeypatch):
    """`CheckedNetworkBackend` overrides `connect_tcp`; renamed, the override is dead code."""

    class _Backend:
        pass

    monkeypatch.setattr(url_guard.httpcore, "SyncBackend", _Backend)
    with pytest.raises(RuntimeError, match="network-backend hook"):
        url_guard.public_http_client(timeout=5)


def test_refusal_names_the_pins_that_have_to_be_revisited(monkeypatch):
    """The fix is a version decision, so the error must point at where those are recorded."""
    class _Transport:
        def __init__(self, *args, **kwargs):
            pass

    monkeypatch.setattr(url_guard.httpx, "HTTPTransport", _Transport)
    with pytest.raises(RuntimeError) as error:
        url_guard.public_http_client(timeout=5)
    assert "requirements.txt" in str(error.value)
