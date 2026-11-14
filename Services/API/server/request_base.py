#!/usr/bin/env python3
"""One implementation of "what is this deployment's public URL?".

`main.py` needs it to hand the app absolute feed URLs, and the browser tools need
it to build the profile callback URL. Both go through here so the proxy-header
handling cannot drift apart between the two surfaces.
"""

from __future__ import annotations

import os

from fastapi import Request


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


def base_url(request: Request) -> str:
    """Public base URL, respecting reverse-proxy forwarding headers.

    `PUBLIC_BASE_URL` (env) wins over header inference — set it when the proxy
    doesn't forward X-Forwarded-Host/X-Forwarded-Proto (e.g. e2b sandbox
    previews), so generated URLs are always ones a client can actually reach.
    """
    override = (os.environ.get("PUBLIC_BASE_URL") or "").strip()
    if override:
        return override.rstrip("/")

    proto = _first_forwarded(request.headers.get("x-forwarded-proto"), request.url.scheme)
    proto = proto.strip().lower() or request.url.scheme
    host = _first_forwarded(
        request.headers.get("x-forwarded-host"), request.headers.get("host", "localhost")
    )
    # Render / e2b proxies terminate TLS; if they omit X-Forwarded-Proto we'd
    # otherwise hand the app a cleartext URL that iOS (ATS) rejects.
    if host.endswith((".e2b.app", ".onrender.com")) and proto == "http":
        proto = "https"
    return f"{proto}://{host}".rstrip("/")
