#!/usr/bin/env python3
"""One implementation of "what is this deployment's public URL?".

`main.py` needs it to hand the app absolute feed URLs, and the browser tools need
it to build the profile callback URL. Both go through here so the proxy-header
handling cannot drift apart between the two surfaces.

The derived base ends up inside URLs the *app* is told to fetch as a premium
source, so it is not merely cosmetic: whoever controls the header that produces
it can point a client at their own feed. Two rules follow from that:

* the host and scheme are validated as a host token and `http`/`https` before
  they are interpolated, so a malformed or injected header cannot produce a URL
  that parses as something else;
* `VEXSIGN_TRUSTED_HOSTS` (comma-separated, `*.example.com` wildcards allowed)
  makes the allowlist explicit. Unset keeps the previous permissive behaviour so
  an existing reverse proxy does not break on upgrade.
"""

from __future__ import annotations

import os
import re

from fastapi import HTTPException, Request

# host[:port], where host is a DNS name, an IPv4 literal or a bracketed IPv6 one.
_HOST_TOKEN = re.compile(r"^(?:\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?)(?::[0-9]{1,5})?$")
_SAFE_SCHEMES = ("http", "https")


def _first_forwarded(value: str | None, default: str) -> str:
    """First entry of a (possibly chained) forwarding header.

    Proxies append to `X-Forwarded-Proto` / `X-Forwarded-Host`, so behind two
    proxies the value looks like `"https, http"` — using it verbatim produced
    broken feed URLs such as `https,http://host/repo/premium.json`. The first
    entry is the client-facing one.
    """
    if not value:
        return default
    return value.split(",")[0].strip() or default


def safe_host(value: str | None) -> str | None:
    """`value` when it is a plain host[:port] token, otherwise None.

    Rejects anything a header could smuggle in: control characters (a CRLF
    would end the header and start a new one), userinfo, paths, and values that
    are not shaped like an authority at all.
    """
    host = (value or "").strip()
    if not host or len(host) > 255:
        return None
    if not _HOST_TOKEN.match(host):
        return None
    return host


def _safe_scheme(value: str | None, default: str) -> str:
    scheme = (value or "").strip().lower()
    return scheme if scheme in _SAFE_SCHEMES else default


def trusted_hosts() -> list[str]:
    raw = os.environ.get("VEXSIGN_TRUSTED_HOSTS", "")
    return [entry.strip().lower() for entry in raw.split(",") if entry.strip()]


def _hostname(host: str) -> str:
    """`host[:port]` -> `host`, keeping IPv6 literals intact."""
    if host.startswith("["):
        closing = host.find("]")
        return host[: closing + 1].lower() if closing > 0 else host.lower()
    return host.split(":", 1)[0].lower()


def _is_trusted(host: str, allowed: list[str]) -> bool:
    hostname = _hostname(host)
    for entry in allowed:
        candidate = _hostname(entry) if entry.startswith("[") else entry.split(":", 1)[0]
        if candidate.startswith("*."):
            suffix = candidate[1:]  # ".example.com"
            if hostname.endswith(suffix) and hostname != suffix.lstrip("."):
                return True
        elif hostname == candidate:
            return True
    return False


def base_url(request: Request) -> str:
    """Public base URL, respecting reverse-proxy forwarding headers.

    `PUBLIC_BASE_URL` (env) wins over header inference — set it when the proxy
    doesn't forward X-Forwarded-Host/X-Forwarded-Proto (e.g. e2b sandbox
    previews), so generated URLs are always ones a client can actually reach.
    """
    override = (os.environ.get("PUBLIC_BASE_URL") or "").strip()
    if override:
        return override.rstrip("/")

    proto = _safe_scheme(
        _first_forwarded(request.headers.get("x-forwarded-proto"), request.url.scheme),
        request.url.scheme,
    )
    host = (
        safe_host(_first_forwarded(request.headers.get("x-forwarded-host"), ""))
        or safe_host(request.headers.get("host"))
        or "localhost"
    )
    # Render / e2b proxies terminate TLS; if they omit X-Forwarded-Proto we'd
    # otherwise hand the app a cleartext URL that iOS (ATS) rejects.
    if host.endswith((".e2b.app", ".onrender.com")) and proto == "http":
        proto = "https"

    allowed = trusted_hosts()
    if allowed and not _is_trusted(host, allowed):
        raise HTTPException(status_code=400, detail="Untrusted Host header for this deployment.")

    return f"{proto}://{host}".rstrip("/")
