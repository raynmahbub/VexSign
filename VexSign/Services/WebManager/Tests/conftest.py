"""Shared pytest setup for the WebManager suite.

Every test drives the app through a `TestClient`, so all of them present the
same peer address and therefore share one throttling bucket per limiter. The
shipped budgets are deliberately small — 20 requests/minute on the admin
surface, because `ADMIN_TOKEN` is a single shared secret with no lockout — which
is far less than a whole suite asks for.

Without a per-test reset, adding a limiter to any route silently starts 429-ing
unrelated tests in other modules, and a test that lowers a budget leaks that
budget into every test after it. Both directions are confusing failures, so the
reset lives here rather than in the one module that happened to notice.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "API"))

import rate_limit  # noqa: E402


def _limiters() -> tuple[tuple[rate_limit.SlidingWindowLimiter, int, float], ...]:
    """Each limiter with the budget it shipped with, read at import time."""
    return (
        (rate_limit.current(), rate_limit.DEFAULT_LIMIT, rate_limit.DEFAULT_WINDOW),
        (rate_limit.current_feed(), rate_limit.FEED_LIMIT, rate_limit.FEED_WINDOW),
        (rate_limit.current_admin(), rate_limit.ADMIN_LIMIT, rate_limit.ADMIN_WINDOW),
    )


@pytest.fixture(autouse=True)
def _fresh_rate_limit_budgets():
    """Empty buckets and shipped settings before each test; empty again after."""
    for limiter, limit, window in _limiters():
        limiter.reset()
        limiter.limit = limit
        limiter.window = window
    yield
    for limiter, _limit, _window in _limiters():
        limiter.reset()
