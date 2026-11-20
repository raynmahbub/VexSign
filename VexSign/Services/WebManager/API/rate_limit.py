#!/usr/bin/env python3
"""Per-client throttling for the endpoints that check credentials.

`POST /api/validate` and `GET /api/urls` are the two places where a caller
presents something guessable: an API key, or a device UUID that only has to
*have* an activation row. Neither endpoint had any limit, so an unauthenticated
peer could try keys or device IDs as fast as the network allows and read the
401/200 difference.

A sliding window keeps that uninteresting: `VEXSIGN_RATE_LIMIT` requests per
`VEXSIGN_RATE_WINDOW_SECONDS` per client, both overridable by an operator who
fronts the service with something else. State is in-process and deliberately
tiny (a deque of timestamps per client, keys evicted when they go quiet), so a
single uvicorn worker needs no extra dependency and a restart simply forgets —
this is a brute-force speed bump, not an accounting system.

Clients are identified by the socket peer. Behind Render or another proxy every
request arrives from the proxy, which would collapse all callers into one
bucket, so set `VEXSIGN_TRUST_FORWARDED_FOR=1` there to use the first
`X-Forwarded-For` entry instead. That header is attacker-controlled, hence the
opt-in: on a directly exposed deployment trusting it would let a client pick a
fresh bucket per request and defeat the limiter entirely.
"""

from __future__ import annotations

import os
import threading
import time
from collections import deque

from fastapi import HTTPException, Request


def _env_int(name: str, default: int, *, minimum: int = 1) -> int:
    raw = os.environ.get(name, "")
    try:
        value = int(raw)
    except (TypeError, ValueError):
        return default
    return value if value >= minimum else default


# 0 (or a negative value) disables throttling entirely, for a deployment that
# already sits behind a WAF or an API gateway.
DEFAULT_LIMIT = _env_int("VEXSIGN_RATE_LIMIT", 60, minimum=0)
DEFAULT_WINDOW = _env_int("VEXSIGN_RATE_WINDOW_SECONDS", 60)
# One bucket per client; anything past this is a flood, and dropping the oldest
# key is cheaper than letting an attacker grow the process out of memory.
_MAX_CLIENTS = 10_000


class SlidingWindowLimiter:
    """At most `limit` events per `window` seconds, per key."""

    def __init__(self, limit: int = DEFAULT_LIMIT, window: float = DEFAULT_WINDOW) -> None:
        self.limit = int(limit)
        self.window = max(0.001, float(window))
        self._events: dict[str, deque[float]] = {}
        self._lock = threading.Lock()

    def retry_after(self, key: str, now: float | None = None) -> float | None:
        """None when the event is allowed (and recorded), else seconds to wait."""
        if self.limit <= 0:
            return None
        moment = time.monotonic() if now is None else now
        cutoff = moment - self.window
        with self._lock:
            events = self._events.get(key)
            if events is None:
                if len(self._events) >= _MAX_CLIENTS:
                    self._events.pop(next(iter(self._events)), None)
                events = deque()
                self._events[key] = events
            while events and events[0] <= cutoff:
                events.popleft()
            if len(events) >= self.limit:
                return max(events[0] + self.window - moment, 0.0)
            events.append(moment)
            return None

    def reset(self) -> None:
        with self._lock:
            self._events.clear()


def _trust_forwarded() -> bool:
    return os.environ.get("VEXSIGN_TRUST_FORWARDED_FOR", "").strip().lower() in {"1", "true", "yes"}


def client_key(request: Request) -> str:
    """Best-effort client identity for the limiter (see the module docstring)."""
    if _trust_forwarded():
        forwarded = request.headers.get("x-forwarded-for", "")
        first = forwarded.split(",")[0].strip()
        if first:
            return first
    peer = request.client.host if request.client else ""
    return peer or "unknown"


_limiter = SlidingWindowLimiter()


def enforce(request: Request) -> None:
    """FastAPI dependency: 429 with `Retry-After` once a client is over budget."""
    wait = _limiter.retry_after(client_key(request))
    if wait is None:
        return
    raise HTTPException(
        status_code=429,
        detail="Too many attempts. Wait a moment and try again.",
        headers={"Retry-After": str(max(1, int(wait + 0.999)))},
    )


def current() -> SlidingWindowLimiter:
    """The process-wide limiter (exposed so tests can reset or inspect it)."""
    return _limiter
