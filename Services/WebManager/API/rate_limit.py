#!/usr/bin/env python3
"""Per-client throttling for every endpoint that checks a credential.

Four surfaces answer a guessable question with a status code, so all four are
budgeted — leaving one unthrottled simply moves the attack there:

* `POST /api/validate` and `GET /api/urls` — an API key, or a device UUID that
  only has to *have* an activation row (`enforce`).
* `GET /repo/premium.json` — accepts the very same `vexSignUUID` / `X-API-Key`
  pair through `_require_premium_access`, and returns 401 or 200 accordingly
  (`enforce_feed`).
* `POST/GET/DELETE /api/admin/*` — one shared `ADMIN_TOKEN`, with no lockout and
  no second factor behind it (`enforce_admin`).

A sliding window keeps guessing uninteresting: a request budget per window per
client, each pair overridable by an operator who fronts the service with
something else (`VEXSIGN_RATE_LIMIT` / `VEXSIGN_RATE_WINDOW_SECONDS`,
`VEXSIGN_FEED_RATE_LIMIT` / `VEXSIGN_FEED_RATE_WINDOW_SECONDS`,
`VEXSIGN_ADMIN_RATE_LIMIT` / `VEXSIGN_ADMIN_RATE_WINDOW_SECONDS`). The three
budgets differ on purpose; see each constant below for why. State is in-process
and deliberately tiny (a deque of timestamps per client), so a single uvicorn
worker needs no extra dependency and a restart simply forgets — this is a
brute-force speed bump, not an accounting system. It is one *process*, so the
effective budget is multiplied by the worker count: keep `uvicorn` at its
default single worker (the `render.yaml` start command does) or add a shared
store before scaling out.

The table is bounded, and it fails closed: once `_MAX_CLIENTS` distinct clients
are being tracked, further new clients are accounted to one shared overflow
bucket instead of evicting an existing one. Evicting would have handed anyone who
can vary their key — which is exactly what a spoofable `X-Forwarded-For` gives —
a way to reset their own budget by flooding new keys.

Clients are identified by the socket peer. Behind Render or another proxy every
request arrives from the proxy, which would collapse all callers into one
bucket, so set `VEXSIGN_TRUST_FORWARDED_FOR=1` there to use the first
`X-Forwarded-For` entry instead. That header is attacker-controlled, hence the
opt-in: on a directly exposed deployment trusting it would let a client pick a
fresh bucket per request and defeat the limiter entirely.
"""

from __future__ import annotations

import ipaddress
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
# The gated feed answers the same "is this credential live?" question as the two
# endpoints above, so it needs a budget too — but a much larger one. Distributors
# hand keys out publicly and their users frequently share a carrier NAT address,
# so one bucket can legitimately cover hundreds of devices refreshing their
# sources. Reusing the 60/min credential budget here would lock out real users;
# an unthrottled route would let a peer hammer SQLite instead. Finite, generous.
FEED_LIMIT = _env_int("VEXSIGN_FEED_RATE_LIMIT", 300, minimum=0)
FEED_WINDOW = _env_int("VEXSIGN_FEED_RATE_WINDOW_SECONDS", 60)
# The admin surface is one human with a phone: minting, listing and revoking are
# a handful of requests. A tight budget makes `ADMIN_TOKEN` expensive to guess
# online, which matters because it is a single shared secret with no lockout.
ADMIN_LIMIT = _env_int("VEXSIGN_ADMIN_RATE_LIMIT", 20, minimum=0)
ADMIN_WINDOW = _env_int("VEXSIGN_ADMIN_RATE_WINDOW_SECONDS", 60)
# UDID session creation (`GET /Tools/udid`) allocates an in-memory session per
# page load; cap per-client creation so a single peer cannot churn the pool.
UDID_LIMIT = _env_int("VEXSIGN_UDID_RATE_LIMIT", 30, minimum=0)
UDID_WINDOW = _env_int("VEXSIGN_UDID_RATE_WINDOW_SECONDS", 60)
# One bucket per client; anything past this is a flood. New clients share one
# overflow bucket rather than evicting a live one (see the module docstring).
_MAX_CLIENTS = 10_000
_OVERFLOW_KEY = "\0overflow"


class SlidingWindowLimiter:
    """At most `limit` events per `window` seconds, per key."""

    def __init__(
        self,
        limit: int = DEFAULT_LIMIT,
        window: float = DEFAULT_WINDOW,
        max_clients: int = _MAX_CLIENTS,
    ) -> None:
        self.limit = int(limit)
        self.window = max(0.001, float(window))
        self.max_clients = max(1, int(max_clients))
        self._events: dict[str, deque[float]] = {}
        self._lock = threading.Lock()
        self._next_prune = 0.0

    def retry_after(self, key: str, now: float | None = None) -> float | None:
        """None when the event is allowed (and recorded), else seconds to wait."""
        if self.limit <= 0:
            return None
        moment = time.monotonic() if now is None else now
        cutoff = moment - self.window
        with self._lock:
            # Reclaim only fully expired budgets, never an active caller's history.
            # Bound sweep frequency so a full table cannot force O(n) per request.
            if moment >= self._next_prune:
                self._events = {client: history for client, history in self._events.items()
                                if history and history[-1] > cutoff}
                self._next_prune = moment + self.window
            events = self._events.get(key)
            if events is None:
                if len(self._events) >= self.max_clients:
                    # Fail closed. Evicting "the oldest" bucket would let a caller who can
                    # vary their key (a spoofable X-Forwarded-For) walk past _MAX_CLIENTS
                    # and reset their own budget; a shared overflow bucket keeps one flood
                    # under one budget instead.
                    key = _OVERFLOW_KEY
                    events = self._events.get(key)
                if events is None:
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
            self._next_prune = 0.0


def _trust_forwarded() -> bool:
    return os.environ.get("VEXSIGN_TRUST_FORWARDED_FOR", "").strip().lower() in {"1", "true", "yes"}


_INTERNAL_PROXY_NETWORKS = (
    ipaddress.ip_network("10.0.0.0/8"),
    ipaddress.ip_network("100.64.0.0/10"),
    ipaddress.ip_network("127.0.0.0/8"),
    ipaddress.ip_network("169.254.0.0/16"),
    ipaddress.ip_network("172.16.0.0/12"),
    ipaddress.ip_network("192.168.0.0/16"),
    ipaddress.ip_network("::1/128"),
    ipaddress.ip_network("fc00::/7"),
    ipaddress.ip_network("fe80::/10"),
)


def _is_internal_proxy_hop(candidate: str) -> bool:
    """True when a trailing X-Forwarded-For hop is a private/loopback internal proxy."""
    try:
        addr = ipaddress.ip_address(candidate.split("%", 1)[0])
    except ValueError:
        return False
    mapped = getattr(addr, "ipv4_mapped", None)
    if mapped is not None:
        addr = mapped
    return any(addr in network for network in _INTERNAL_PROXY_NETWORKS)


def client_key(request: Request) -> str:
    """Best-effort client identity for the limiter (see the module docstring).

    When `VEXSIGN_TRUST_FORWARDED_FOR=1` is set behind a reverse proxy, reading
    the leftmost entry (`entries[0]`) would let an attacker spoof an arbitrary
    `X-Forwarded-For` header on every request to evade rate limits. Instead:
      * if `VEXSIGN_TRUSTED_PROXY_HOPS` is explicitly configured (`>= 1`), select
        that many hops from the right (`entries[-hops]`); a header with fewer
        entries than hops did not come through every proxy, so the socket peer
        is used instead of trusting it;
      * otherwise walk right-to-left skipping trailing private/loopback internal
        load-balancer hops so the rightmost untrusted client IP added by the
        trusted edge proxy is selected.
    """
    if _trust_forwarded():
        forwarded = request.headers.get("x-forwarded-for", "")
        entries = [part.strip() for part in forwarded.split(",") if part.strip()]
        if entries:
            raw_hops = os.environ.get("VEXSIGN_TRUSTED_PROXY_HOPS", "").strip()
            if raw_hops:
                hops = _env_int("VEXSIGN_TRUSTED_PROXY_HOPS", 1, minimum=1)
                if len(entries) < hops:
                    # The header is short by at least one hop, so this request did not
                    # traverse every trusted proxy: it is direct traffic wearing a forged
                    # header. Indexing anyway would clamp to entries[0] — the value the
                    # caller chose — and hand them a fresh bucket per request.
                    peer = request.client.host if request.client else ""
                    return peer or "unknown"
                return entries[len(entries) - hops]
            for candidate in reversed(entries):
                if not _is_internal_proxy_hop(candidate):
                    return candidate
            return entries[-1]
    peer = request.client.host if request.client else ""
    return peer or "unknown"


_limiter = SlidingWindowLimiter()
_feed_limiter = SlidingWindowLimiter(limit=FEED_LIMIT, window=FEED_WINDOW)
_admin_limiter = SlidingWindowLimiter(limit=ADMIN_LIMIT, window=ADMIN_WINDOW)
_udid_limiter = SlidingWindowLimiter(limit=UDID_LIMIT, window=UDID_WINDOW)


def _reject_when_over_budget(limiter: SlidingWindowLimiter, request: Request) -> None:
    wait = limiter.retry_after(client_key(request))
    if wait is None:
        return
    raise HTTPException(
        status_code=429,
        detail="Too many attempts. Wait a moment and try again.",
        headers={"Retry-After": str(max(1, int(wait + 0.999)))},
    )


def enforce(request: Request) -> None:
    """FastAPI dependency: 429 with `Retry-After` once a client is over budget."""
    _reject_when_over_budget(_limiter, request)


def enforce_feed(request: Request) -> None:
    """Throttle the gated feed, which checks the same credentials on a larger budget."""
    _reject_when_over_budget(_feed_limiter, request)


def enforce_admin(request: Request) -> None:
    """Throttle the token-gated admin surface, so `ADMIN_TOKEN` is expensive to guess."""
    _reject_when_over_budget(_admin_limiter, request)


def enforce_udid(request: Request) -> None:
    """Throttle UDID session-creating page loads per client."""
    _reject_when_over_budget(_udid_limiter, request)


def current() -> SlidingWindowLimiter:
    """The process-wide limiter (exposed so tests can reset or inspect it)."""
    return _limiter


def current_feed() -> SlidingWindowLimiter:
    """The gated-feed limiter (exposed so tests can reset or inspect it)."""
    return _feed_limiter


def current_admin() -> SlidingWindowLimiter:
    """The admin limiter (exposed so tests can reset or inspect it)."""
    return _admin_limiter


def current_udid() -> SlidingWindowLimiter:
    """The UDID session-creation limiter (exposed so tests can reset or inspect it)."""
    return _udid_limiter
