#!/usr/bin/env python3
"""Public-URL SSRF guard for outbound server fetches (`app_installer`, `repo_decoder`).

Unlike `web_signer.py` (which relays to a user's LAN Web Manager and therefore
restricts targets to private addresses), the App Installer probe and Repository
Decoder fetch public internet URLs supplied by users. Outbound connections must
never reach loopback, RFC-1918 private networks, link-local / cloud metadata
endpoints (169.254.0.0/16, fe80::/10), CGNAT (100.64.0.0/10), or internal
hostnames — neither on the initial URL nor on any HTTP redirect hop.
"""

from __future__ import annotations

import ipaddress
import socket
from typing import Any
from urllib.parse import urlparse

try:
    import httpx
except ImportError:  # pragma: no cover
    httpx = None  # type: ignore[assignment]

EXTRA_BLOCKED_NETWORKS = (
    ipaddress.ip_network("0.0.0.0/8"),
    ipaddress.ip_network("100.64.0.0/10"),
    ipaddress.ip_network("192.0.0.0/24"),
    ipaddress.ip_network("198.18.0.0/15"),
    ipaddress.ip_network("fc00::/7"),
    ipaddress.ip_network("fe80::/10"),
    ipaddress.ip_network("fec0::/10"),
)

BLOCKED_HOSTNAMES = frozenset({"localhost", "localhost.localdomain", "metadata", "metadata.google.internal"})
BLOCKED_SUFFIXES = (".localhost", ".local", ".internal", ".localdomain")


def _default_resolve_ips(host: str, port: int) -> set[ipaddress.IPv4Address | ipaddress.IPv6Address]:
    infos = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
    return {ipaddress.ip_address(info[4][0].split("%", 1)[0]) for info in infos}


# Seam for unit tests to simulate DNS resolutions deterministically without touching the network.
_resolve_ips = _default_resolve_ips


def _is_public_address(address: ipaddress.IPv4Address | ipaddress.IPv6Address) -> bool:
    mapped = getattr(address, "ipv4_mapped", None)
    if mapped is not None:
        address = mapped
    if (
        address.is_private
        or address.is_loopback
        or address.is_link_local
        or address.is_multicast
        or address.is_reserved
        or address.is_unspecified
    ):
        return False
    if any(address in network for network in EXTRA_BLOCKED_NETWORKS):
        return False
    return address.is_global


def should_resolve_dns(client: Any | None = None) -> bool:
    """Resolve DNS in production and whenever a test overrides `_resolve_ips`.

    Tests that only swap `httpx.MockTransport` (to avoid touching the network) still
    get full scheme, credential, hostname, and literal-IP validation on every hop.
    """
    if _resolve_ips is not _default_resolve_ips:
        return True
    transport = getattr(client, "_transport", None)
    if httpx is not None and isinstance(transport, httpx.MockTransport):
        return False
    return True


def public_url_error(raw: str, *, resolve_dns: bool = True) -> str | None:
    """Return a human-readable refusal reason if `raw` is not a safe public HTTP(S) URL."""
    url = (raw or "").strip()
    if not url:
        return "Give an http:// or https:// URL."

    try:
        parsed = urlparse(url)
    except ValueError:
        return "That address is not a valid URL."
    if parsed.scheme.lower() not in ("http", "https"):
        return "Only http:// and https:// addresses are accepted."
    if parsed.username is not None or parsed.password is not None:
        return "URLs with embedded credentials are not accepted."

    # `urlparse().port` raises for out-of-range and non-numeric ports. Validate it
    # before either the DNS-resolution path or the fast path: a malformed port used
    # to escape the fast path entirely and crash the DNS path with an uncaught
    # ValueError, turning a user-supplied URL into a 500 on public endpoints.
    try:
        explicit_port = parsed.port
    except ValueError:
        return "That address has an invalid port."
    if explicit_port == 0:
        return "That address has an invalid port."
    port = explicit_port or (443 if parsed.scheme.lower() == "https" else 80)

    try:
        host = (parsed.hostname or "").strip().rstrip(".").lower()
    except ValueError:
        return "That address has an invalid hostname."
    if not host:
        return "That address has no hostname."
    if host in BLOCKED_HOSTNAMES or any(host.endswith(suffix) for suffix in BLOCKED_SUFFIXES):
        return f"'{host}' is a private or internal hostname and cannot be fetched."

    try:
        literal = ipaddress.ip_address(host.split("%", 1)[0])
    except ValueError:
        literal = None

    if literal is not None:
        if not _is_public_address(literal):
            return f"'{host}' is not a public IP address."
        return None

    if not resolve_dns:
        return None

    try:
        addresses = _resolve_ips(host, port)
    except (socket.gaierror, OSError, ValueError):
        return f"'{host}' did not resolve."

    if not addresses:
        return f"'{host}' did not resolve."

    for address in addresses:
        if not _is_public_address(address):
            return f"'{host}' resolves to {address}, which is not a public IP address."
    return None
