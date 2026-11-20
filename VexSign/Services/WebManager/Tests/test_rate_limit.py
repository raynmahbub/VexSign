"""Throttling on the credential-checking endpoints, and the `/api/urls` contract.

`POST /api/validate` answers 401/200 based on a key, and `GET /api/urls` answers
based on a device UUID that only has to *have* an activation. Both were
unlimited, so a peer could brute-force either at line speed. These tests pin the
two properties that matter:

* a client over budget gets 429 with `Retry-After`, and only that client is
  affected;
* the limiter is a speed bump, not an authorization change — the endpoint still
  refuses an unknown device, still accepts a valid key, and an operator can turn
  throttling off without editing code.

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

_TMP = tempfile.mkdtemp(prefix="vexsign-ratelimit-test-")
os.environ.setdefault("VEXSIGN_DB", os.path.join(_TMP, "vexsign.db"))
os.environ.setdefault("REPO_STORE_DIR", os.path.join(_TMP, "store"))
os.environ.pop("VEXSIGN_TRUST_FORWARDED_FOR", None)
os.environ.pop("VEXSIGN_RATE_LIMIT", None)

import db  # noqa: E402
import main  # noqa: E402
import rate_limit  # noqa: E402


@pytest.fixture
def client():
    with TestClient(main.app) as test_client:
        yield test_client


@pytest.fixture(autouse=True)
def _fresh_limiter(monkeypatch):
    """Each test starts with an empty budget and the shipped settings."""
    monkeypatch.delenv("VEXSIGN_TRUST_FORWARDED_FOR", raising=False)
    rate_limit.current().reset()
    rate_limit.current().limit = rate_limit.DEFAULT_LIMIT
    rate_limit.current().window = rate_limit.DEFAULT_WINDOW
    yield
    rate_limit.current().reset()


# ---------------------------------------------------------------------------
# The limiter itself
# ---------------------------------------------------------------------------


def test_window_allows_exactly_the_budget_then_refuses():
    limiter = rate_limit.SlidingWindowLimiter(limit=3, window=60)
    assert [limiter.retry_after("peer", now=100.0) for _ in range(3)] == [None, None, None]

    wait = limiter.retry_after("peer", now=100.0)
    assert wait is not None and wait > 0


def test_window_slides_so_the_budget_returns():
    limiter = rate_limit.SlidingWindowLimiter(limit=2, window=10)
    assert limiter.retry_after("peer", now=0.0) is None
    assert limiter.retry_after("peer", now=1.0) is None
    assert limiter.retry_after("peer", now=2.0) is not None
    # 10s after the first event its slot is free again, 11s after the second.
    assert limiter.retry_after("peer", now=10.5) is None
    assert limiter.retry_after("peer", now=11.5) is None


def test_budget_is_per_client():
    limiter = rate_limit.SlidingWindowLimiter(limit=1, window=60)
    assert limiter.retry_after("a", now=0.0) is None
    assert limiter.retry_after("a", now=0.0) is not None
    assert limiter.retry_after("b", now=0.0) is None


def test_limiter_reports_time_remaining_not_a_flat_value():
    limiter = rate_limit.SlidingWindowLimiter(limit=1, window=30)
    limiter.retry_after("peer", now=0.0)
    assert limiter.retry_after("peer", now=10.0) == pytest.approx(20.0)


def test_zero_budget_disables_the_limiter():
    limiter = rate_limit.SlidingWindowLimiter(limit=0, window=60)
    for _ in range(50):
        assert limiter.retry_after("peer", now=0.0) is None


def test_client_key_ignores_forwarded_for_unless_opted_in(monkeypatch):
    """Trusting the header by default would let a client pick its own bucket."""
    monkeypatch.setenv("VEXSIGN_TRUST_FORWARDED_FOR", "1")

    class _Peer:
        host = "10.0.0.1"

    class _Request:
        headers = {"x-forwarded-for": "203.0.113.9, 10.0.0.1"}
        client = _Peer()

    assert rate_limit.client_key(_Request()) == "203.0.113.9"
    monkeypatch.delenv("VEXSIGN_TRUST_FORWARDED_FOR")
    assert rate_limit.client_key(_Request()) == "10.0.0.1"


def test_client_key_survives_a_missing_peer():
    class _Request:
        headers = {}
        client = None

    assert rate_limit.client_key(_Request()) == "unknown"


# ---------------------------------------------------------------------------
# The endpoints
# ---------------------------------------------------------------------------


def test_urls_is_throttled_after_the_budget(client):
    rate_limit.current().limit = 2
    rate_limit.current().window = 60
    unknown = {"vexSignUUID": "00000000-0000-0000-0000-000000000000"}

    assert client.get("/api/urls", headers=unknown).status_code == 401
    assert client.get("/api/urls", headers=unknown).status_code == 401

    limited = client.get("/api/urls", headers=unknown)
    assert limited.status_code == 429
    assert int(limited.headers["retry-after"]) >= 1
    assert "too many attempts" in limited.json()["detail"].lower()


def test_validate_is_throttled_before_the_key_is_even_looked_at(client):
    rate_limit.current().limit = 1

    first = client.post("/api/validate", json={"device_uuid": "dev-1"}, headers={"X-API-Key": "NOPE"})
    assert first.status_code == 401

    limited = client.post("/api/validate", json={"device_uuid": "dev-1"}, headers={"X-API-Key": "NOPE"})
    assert limited.status_code == 429


def test_health_is_never_throttled(client):
    rate_limit.current().limit = 1
    client.get("/api/urls", headers={"vexSignUUID": "nobody"})
    assert client.get("/api/health").status_code == 200


def test_urls_still_refuses_an_unknown_device(client):
    response = client.get("/api/urls", headers={"vexSignUUID": "not-a-registered-device"})
    assert response.status_code == 401
    assert response.json()["detail"] == main.NO_ACTIVATION_DETAIL


def test_urls_accepts_an_activated_device_without_an_api_key(client):
    """The installed client base only sends `vexSignUUID`; that must keep working."""
    db.add_key("VEX-URLS-DEVICE-1")
    assert db.consume_key("VEX-URLS-DEVICE-1", "device-urls-1")

    response = client.get("/api/urls", headers={"vexSignUUID": "device-urls-1"})
    assert response.status_code == 200
    assert response.json()["urls"]


def test_urls_accepts_an_api_key_as_the_alternative_credential(client):
    """A script holding a redeemed key does not have to know the device UUID."""
    db.add_key("VEX-URLS-KEY-1")
    assert db.consume_key("VEX-URLS-KEY-1", "device-urls-key-1")

    response = client.get("/api/urls", headers={"X-API-Key": "vex-urls-key-1"})
    assert response.status_code == 200
    assert response.json()["urls"]

    # Same key, wrong case/spacing: keys are stored upper-cased and trimmed.
    assert client.get("/api/urls", headers={"X-API-Key": "  Vex-Urls-Key-1  "}).status_code == 200


def test_urls_rejects_an_unredeemed_key(client):
    """An unused key is not a credential yet: it still belongs to whoever redeems it."""
    db.add_key("VEX-URLS-UNUSED-1")
    response = client.get("/api/urls", headers={"X-API-Key": "VEX-URLS-UNUSED-1"})
    assert response.status_code == 401


def test_urls_rejects_a_wrong_api_key(client):
    response = client.get("/api/urls", headers={"X-API-Key": "VEX-DOES-NOT-EXIST"})
    assert response.status_code == 401


# ---------------------------------------------------------------------------
# The gated feed: the same credentials, on a budget of its own
# ---------------------------------------------------------------------------


def test_premium_feed_is_throttled_after_its_budget(client):
    """/repo/premium.json answers the same 401-vs-200 question as /api/urls.

    It accepts the identical `vexSignUUID` / `X-API-Key` pair through
    `_require_premium_access`, so leaving it unthrottled only moved the
    enumeration off the two routes that were limited.
    """
    rate_limit.current_feed().limit = 2
    rate_limit.current_feed().window = 60
    unknown = {"vexSignUUID": "00000000-0000-0000-0000-000000000000"}

    assert client.get("/repo/premium.json", headers=unknown).status_code == 401
    assert client.get("/repo/premium.json", headers=unknown).status_code == 401

    limited = client.get("/repo/premium.json", headers=unknown)
    assert limited.status_code == 429
    assert int(limited.headers["retry-after"]) >= 1
    assert "too many attempts" in limited.json()["detail"].lower()


def test_feed_budget_is_separate_from_the_credential_budget(client):
    """Distributor users frequently share a carrier NAT address, so the feed gets more room."""
    rate_limit.current().limit = 1
    rate_limit.current_feed().limit = 5

    assert client.get("/api/urls", headers={"vexSignUUID": "nobody"}).status_code == 401
    assert client.get("/api/urls", headers={"vexSignUUID": "nobody"}).status_code == 429
    # The credential endpoint is over budget; the feed has not spent anything.
    assert client.get("/repo/premium.json", headers={"vexSignUUID": "nobody"}).status_code == 401


def test_premium_feed_still_serves_an_activated_device(client):
    """Throttling is a speed bump, not an authorization change."""
    db.add_key("VEX-FEED-DEVICE-1")
    assert db.consume_key("VEX-FEED-DEVICE-1", "device-feed-1")

    response = client.get("/repo/premium.json", headers={"vexSignUUID": "device-feed-1"})
    assert response.status_code == 200
    assert response.json()["apps"]


def test_public_source_is_never_throttled(client):
    """/repo/source.json checks no credential, so it must not inherit a budget."""
    rate_limit.current().limit = 1
    rate_limit.current_feed().limit = 1
    client.get("/repo/premium.json", headers={"vexSignUUID": "nobody"})
    client.get("/api/urls", headers={"vexSignUUID": "nobody"})

    assert client.get("/repo/source.json").status_code == 200
    assert client.get("/api/health").status_code == 200
