"""Tests for the premium key admin API, the keygen CLI and the key store.

These are the distributor-facing controls: minting, disabling and revoking keys.
The auth boundary matters more than the happy path here, so the disabled-surface
and wrong-token cases are asserted for *every* mutating route.

Run from `Services/WebManager/API/`:

    python -m pytest ../Tests/ -q
"""

from __future__ import annotations

import os
import re
import sys
import tempfile
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "API"))

_TMP = tempfile.mkdtemp(prefix="vexsign-admin-test-")
os.environ.setdefault("VEXSIGN_DB", os.path.join(_TMP, "vexsign.db"))
os.environ.setdefault("REPO_STORE_DIR", os.path.join(_TMP, "store"))
os.environ["ADMIN_TOKEN"] = "test-admin-token"

import admin  # noqa: E402
import db  # noqa: E402
import keygen  # noqa: E402
import main  # noqa: E402
import rate_limit  # noqa: E402

TOKEN = "test-admin-token"
HEADERS = {"X-Admin-Token": TOKEN}
KEY_PATTERN = re.compile(r"^VEX-[A-Z2-9]{4}-[A-Z2-9]{4}-[A-Z2-9]{4}$")

MUTATING = [
    ("POST", "/api/admin/keys", {"count": 1}),
    ("POST", "/api/admin/keys/disable", {"key": "VEX-AAAA-AAAA-AAAA"}),
    ("POST", "/api/admin/keys/enable", {"key": "VEX-AAAA-AAAA-AAAA"}),
    ("POST", "/api/admin/keys/reset", {"key": "VEX-AAAA-AAAA-AAAA"}),
    ("POST", "/api/admin/keys/revoke", {"key": "VEX-AAAA-AAAA-AAAA"}),
]


@pytest.fixture(autouse=True)
def isolated_keys(tmp_path, monkeypatch):
    """Every test starts with an empty key table, a known token and a full budget.

    The admin limiter is process-wide and this module makes many admin calls, so without
    the reset the suite itself spends the 20/minute budget and later tests see 429.
    """
    monkeypatch.setattr(db, "DB_PATH", str(tmp_path / "keys.db"))
    monkeypatch.setattr(admin, "ADMIN_TOKEN", TOKEN)
    monkeypatch.delenv("ADMIN_TOKEN_FILE", raising=False)
    limiter = rate_limit.current_admin()
    limiter.reset()
    limiter.limit = rate_limit.ADMIN_LIMIT
    limiter.window = rate_limit.ADMIN_WINDOW
    yield
    limiter.reset()


@pytest.fixture
def client():
    with TestClient(main.app) as test_client:
        yield test_client


def mint(client, count=1):
    response = client.post("/api/admin/keys", json={"count": count}, headers=HEADERS)
    assert response.status_code == 200, response.text
    return response.json()["keys"]


# ---------------------------------------------------------------------------
# Auth boundary
# ---------------------------------------------------------------------------

def test_token_comparison_handles_missing_wrong_and_non_ascii():
    assert admin.is_valid_admin_token(TOKEN) is True
    assert admin.is_valid_admin_token("wrong") is False
    assert admin.is_valid_admin_token(None) is False
    assert admin.is_valid_admin_token("") is False
    # compare_digest raises TypeError on non-ASCII str; the guard must swallow it.
    assert admin.is_valid_admin_token("tökén") is False


def test_no_configured_token_disables_the_surface(monkeypatch):
    monkeypatch.setattr(admin, "ADMIN_TOKEN", "")
    assert admin.is_valid_admin_token(TOKEN) is False
    assert admin.is_valid_admin_token("") is False


@pytest.mark.parametrize("method,path,body", MUTATING)
def test_mutating_routes_reject_a_missing_or_wrong_token(client, method, path, body):
    assert client.request(method, path, json=body).status_code == 403
    assert client.request(method, path, json=body,
                          headers={"X-Admin-Token": "wrong"}).status_code == 403


def test_listing_keys_requires_the_token(client):
    assert client.get("/api/admin/keys").status_code == 403
    assert client.get("/api/admin/keys", headers={"X-Admin-Token": "wrong"}).status_code == 403


@pytest.mark.parametrize("method,path,body", MUTATING)
def test_every_mutating_route_is_403_when_admin_is_disabled(client, monkeypatch, method, path, body):
    monkeypatch.setattr(admin, "ADMIN_TOKEN", "")
    # Even the correct-looking token must not work while the surface is off.
    assert client.request(method, path, json=body, headers=HEADERS).status_code == 403


def test_health_reports_whether_admin_is_enabled_without_a_token(client, monkeypatch):
    assert client.get("/api/admin/health").json() == {"enabled": True}
    monkeypatch.setattr(admin, "ADMIN_TOKEN", "")
    assert client.get("/api/admin/health").json() == {"enabled": False}


# ---------------------------------------------------------------------------
# Minting
# ---------------------------------------------------------------------------

def test_minted_keys_are_unique_unambiguous_and_fresh(client):
    keys = mint(client, 12)
    assert len(set(keys)) == 12
    for key in keys:
        assert KEY_PATTERN.match(key), key
        # O/0 and I/1 are excluded so a key read off a screen types back cleanly.
        assert not set(key.replace("VEX-", "")) & set("OI01")
        row = db.get_key(key)
        assert row["used"] == 0 and row["disabled"] == 0 and row["device_uuid"] is None


@pytest.mark.parametrize("count", [0, -1, 251, 1000])
def test_mint_rejects_out_of_range_counts(client, count):
    response = client.post("/api/admin/keys", json={"count": count}, headers=HEADERS)
    assert response.status_code == 400
    assert "between 1 and 250" in response.json()["detail"]


def test_mint_defaults_to_one_key(client):
    response = client.post("/api/admin/keys", json={}, headers=HEADERS)
    assert response.status_code == 200
    assert response.json()["count"] == 1


def _reveal(client, key_id):
    response = client.post("/api/admin/keys/reveal", json={"id": key_id}, headers=HEADERS)
    assert response.status_code == 200, response.text
    return response.json()["key"]


def test_listing_reports_fresh_used_and_disabled_states(client):
    fresh, used, disabled = mint(client, 3)
    db.consume_key(used, "device-uuid")
    db.set_key_disabled(disabled, True)

    listed = client.get("/api/admin/keys", headers=HEADERS).json()["keys"]
    rows = {_reveal(client, row["id"]): row for row in listed}
    assert rows[fresh]["status"] == "fresh"
    assert rows[used]["status"] == "used"
    assert rows[used]["device_uuid"] == "device-uuid"
    # Disabled wins over used in the reported status.
    assert rows[disabled]["status"] == "disabled"


# ---------------------------------------------------------------------------
# The list is not a key dump
# ---------------------------------------------------------------------------

MASK = re.compile(r"^\*{4}-\*{4}-[A-Z2-9]{4}$")


def test_listing_withholds_key_material(client):
    """One authenticated GET used to return every customer's working key.

    `SEED_KEYS` is set by another test module at import time, so the table may hold more
    rows than this test minted; the assertions are about the minted ones.
    """
    minted = mint(client, 4)
    listed = client.get("/api/admin/keys", headers=HEADERS).json()["keys"]

    assert {row["key"] for row in listed}.isdisjoint(minted)
    for row in listed:
        assert MASK.match(row["key"]), row["key"]
        assert re.match(r"^[0-9a-f]{12}$", row["id"]), row["id"]
    # The mask keeps the tail, which is what matches a customer's screenshot.
    tails = tuple(key[-4:] for key in minted)
    assert len([row for row in listed if row["key"].endswith(tails)]) >= len(minted)


def test_ids_are_stable_and_distinct(client):
    mint(client, 3)
    first = [row["id"] for row in client.get("/api/admin/keys", headers=HEADERS).json()["keys"]]
    second = [row["id"] for row in client.get("/api/admin/keys", headers=HEADERS).json()["keys"]]
    assert first == second
    assert len(set(first)) == len(first)


def test_reveal_returns_one_key_and_accepts_the_key_itself(client):
    key = mint(client)[0]
    key_id = client.get("/api/admin/keys", headers=HEADERS).json()["keys"][0]["id"]

    assert _reveal(client, key_id) == key
    response = client.post("/api/admin/keys/reveal", json={"key": key}, headers=HEADERS)
    assert response.json()["key"] == key


def test_reveal_refuses_an_unknown_selector(client):
    assert client.post("/api/admin/keys/reveal", json={"id": "0" * 12},
                       headers=HEADERS).status_code == 404
    assert client.post("/api/admin/keys/reveal", json={}, headers=HEADERS).status_code == 400
    assert client.post("/api/admin/keys/reveal", json={"id": "0" * 12}).status_code == 403


# ---------------------------------------------------------------------------
# Audit trail
# ---------------------------------------------------------------------------

def test_mutations_and_reveals_are_audited_but_reads_are_not(client):
    key = mint(client)[0]
    key_id = client.get("/api/admin/keys", headers=HEADERS).json()["keys"][0]["id"]
    client.post("/api/admin/keys/disable", json={"key": key}, headers=HEADERS)
    client.post("/api/admin/keys/reveal", json={"id": key_id}, headers=HEADERS)

    actions = client.get("/api/admin/audit", headers=HEADERS).json()["actions"]
    names = [row["action"] for row in actions]
    assert "key.minted" in names and "key.disabled" in names and "key.revealed" in names
    # Listing the keys must not fill the trail.
    assert "key.listed" not in names
    for row in actions:
        assert row["key_id"] is None or re.match(r"^[0-9a-f]{12}$", row["key_id"]), row["key_id"]
        assert key not in (row["key_id"] or "")


def test_audit_requires_the_token(client):
    assert client.get("/api/admin/audit").status_code == 403


# ---------------------------------------------------------------------------
# Rotation without a redeploy
# ---------------------------------------------------------------------------

def test_a_token_list_accepts_either_secret(monkeypatch):
    monkeypatch.setattr(admin, "ADMIN_TOKEN", "old-token,new-token")
    assert admin.is_valid_admin_token("old-token") is True
    assert admin.is_valid_admin_token("new-token") is True
    assert admin.is_valid_admin_token("other") is False


def test_a_token_file_is_read_per_request_and_wins(monkeypatch, tmp_path):
    path = tmp_path / "admin-token"
    path.write_text("file-token\n", encoding="utf-8")
    monkeypatch.setattr(admin, "ADMIN_TOKEN", "import-token")
    monkeypatch.setenv("ADMIN_TOKEN_FILE", str(path))

    assert admin.is_valid_admin_token("file-token") is True
    assert admin.is_valid_admin_token("import-token") is False

    # Rotation is a file write, not a redeploy.
    path.write_text("rotated-token\n", encoding="utf-8")
    assert admin.is_valid_admin_token("rotated-token") is True
    assert admin.is_valid_admin_token("file-token") is False


def test_an_unreadable_token_file_disables_the_surface(monkeypatch, tmp_path):
    """Falling back to the previous secret would defeat the point of rotating it."""
    monkeypatch.setenv("ADMIN_TOKEN_FILE", str(tmp_path / "missing"))
    assert admin.admin_enabled() is False
    assert admin.is_valid_admin_token(TOKEN) is False


# ---------------------------------------------------------------------------
# Mutations
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("action", ["disable", "enable", "reset", "revoke"])
def test_unknown_key_is_404(client, action):
    response = client.post(f"/api/admin/keys/{action}",
                           json={"key": "VEX-ZZZZ-ZZZZ-ZZZZ"}, headers=HEADERS)
    assert response.status_code == 404


@pytest.mark.parametrize("action", ["disable", "enable", "reset", "revoke"])
def test_missing_key_field_is_404_not_a_crash(client, action):
    response = client.post(f"/api/admin/keys/{action}", json={}, headers=HEADERS)
    assert response.status_code == 404


def test_key_is_normalised_before_lookup(client):
    key = mint(client)[0]
    response = client.post("/api/admin/keys/disable",
                           json={"key": f"  {key.lower()}  "}, headers=HEADERS)
    assert response.status_code == 200
    assert response.json()["key"] == key
    assert db.get_key(key)["disabled"] == 1


def test_disable_then_enable_round_trip(client):
    key = mint(client)[0]
    db.consume_key(key, "device-uuid")
    client.post("/api/admin/keys/disable", json={"key": key}, headers=HEADERS)
    assert db.key_allows_downloads(key) is False
    client.post("/api/admin/keys/enable", json={"key": key}, headers=HEADERS)
    assert db.key_allows_downloads(key) is True


def test_reset_unbinds_the_device_and_frees_the_key(client):
    key = mint(client)[0]
    assert db.consume_key(key, "first-device") is True
    assert db.device_has_activation("first-device") is True

    response = client.post("/api/admin/keys/reset", json={"key": key}, headers=HEADERS)
    assert response.status_code == 200
    row = db.get_key(key)
    assert row["used"] == 0 and row["device_uuid"] is None
    assert db.device_has_activation("first-device") is False
    # The freed key can be claimed by another device.
    assert db.consume_key(key, "second-device") is True


def test_revoke_deletes_the_key(client):
    key = mint(client)[0]
    response = client.post("/api/admin/keys/revoke", json={"key": key}, headers=HEADERS)
    assert response.status_code == 200
    assert db.get_key(key) is None
    assert db.key_allows_downloads(key) is False


# ---------------------------------------------------------------------------
# Key store semantics the admin surface depends on
# ---------------------------------------------------------------------------

def test_consume_is_atomic_and_idempotent():
    db.add_key("VEX-AAAA-BBBB-CCCC")
    assert db.consume_key("VEX-AAAA-BBBB-CCCC", "device-1") is True
    # A second claim — even by the same device — must not succeed.
    assert db.consume_key("VEX-AAAA-BBBB-CCCC", "device-1") is False
    assert db.consume_key("VEX-AAAA-BBBB-CCCC", "device-2") is False
    assert db.get_key("VEX-AAAA-BBBB-CCCC")["device_uuid"] == "device-1"


def test_disabled_key_cannot_be_consumed_or_download():
    db.add_key("VEX-DDDD-EEEE-FFFF")
    db.set_key_disabled("VEX-DDDD-EEEE-FFFF", True)
    assert db.consume_key("VEX-DDDD-EEEE-FFFF", "device-1") is False
    assert db.key_allows_downloads("VEX-DDDD-EEEE-FFFF") is False
    assert db.device_has_activation("device-1") is False


def test_fresh_key_does_not_allow_downloads():
    db.add_key("VEX-GGGG-HHHH-JJJJ")
    assert db.key_allows_downloads("VEX-GGGG-HHHH-JJJJ") is False
    assert db.key_allows_downloads("VEX-NOPE-NOPE-NOPE") is False


def test_reset_and_delete_are_safe_on_unknown_keys():
    db.reset_key("VEX-NOPE-NOPE-NOPE")
    db.delete_key("VEX-NOPE-NOPE-NOPE")
    db.set_key_disabled("VEX-NOPE-NOPE-NOPE", True)
    assert db.get_key("VEX-NOPE-NOPE-NOPE") is None


# ---------------------------------------------------------------------------
# keygen CLI (same operations, shell-side)
# ---------------------------------------------------------------------------

def test_generated_keys_match_the_shared_alphabet():
    for _ in range(25):
        key = keygen.generate_key()
        assert KEY_PATTERN.match(key), key
        assert not set(key.replace("VEX-", "")) & set("OI01")


def test_cli_create_prints_and_stores_keys(capsys):
    keygen.cmd_create(3)
    printed = capsys.readouterr().out.split()
    assert len(printed) == 3
    for key in printed:
        assert db.get_key(key) is not None


def test_cli_add_rejects_a_duplicate(capsys):
    keygen.cmd_add("VEX-AAAA-BBBB-CCCC")
    capsys.readouterr()
    with pytest.raises(SystemExit):
        keygen.cmd_add("VEX-AAAA-BBBB-CCCC")


def test_cli_flag_commands_normalise_and_report_unknown_keys(capsys):
    db.add_key("VEX-AAAA-BBBB-CCCC")
    keygen._set_flag("  vex-aaaa-bbbb-cccc  ",
                     "UPDATE keys SET disabled = 1 WHERE api_key = ?", "Disabled")
    assert db.get_key("VEX-AAAA-BBBB-CCCC")["disabled"] == 1
    capsys.readouterr()
    with pytest.raises(SystemExit):
        keygen._set_flag("VEX-NOPE-NOPE-NOPE",
                         "UPDATE keys SET disabled = 1 WHERE api_key = ?", "Disabled")


def test_cli_list_handles_an_empty_table(capsys):
    keygen.cmd_list()
    assert "No keys" in capsys.readouterr().out


def test_cli_list_labels_key_states(capsys):
    db.add_key("VEX-FRESH-AAAA-BBBB")
    db.add_key("VEX-USEDX-AAAA-BBBB")
    db.consume_key("VEX-USEDX-AAAA-BBBB", "abcdefgh-rest-of-uuid")
    db.add_key("VEX-OFFXX-AAAA-BBBB")
    db.set_key_disabled("VEX-OFFXX-AAAA-BBBB", True)

    keygen.cmd_list()
    out = capsys.readouterr().out
    assert "[FRESH]" in out and "[USED]" in out and "[DISABLED]" in out
    # Only a device prefix is printed, never the whole identifier.
    assert "abcdefgh…" in out
    assert "rest-of-uuid" not in out


# ---------------------------------------------------------------------------
# Throttling. `ADMIN_TOKEN` is one shared secret with no lockout and no second
# factor, so the only thing standing between a peer and unlimited online
# guessing is this budget. See rate_limit.ADMIN_LIMIT.
# ---------------------------------------------------------------------------


def test_admin_routes_are_throttled_after_their_budget(client):
    rate_limit.current_admin().limit = 2
    rate_limit.current_admin().window = 60

    assert client.get("/api/admin/keys", headers=HEADERS).status_code == 200
    assert client.get("/api/admin/keys", headers=HEADERS).status_code == 200

    limited = client.get("/api/admin/keys", headers=HEADERS)
    assert limited.status_code == 429
    assert int(limited.headers["retry-after"]) >= 1


def test_every_token_gated_route_carries_the_budget(client):
    """The throttle has to cover the whole surface, or guessing just moves route."""
    rate_limit.current_admin().limit = 1
    for method, path, body in MUTATING + [("GET", "/api/admin/keys", None), ("GET", "/api/admin/apps", None)]:
        rate_limit.current_admin().reset()
        first = client.request(method, path, headers=HEADERS, json=body)
        second = client.request(method, path, headers=HEADERS, json=body)
        assert first.status_code != 429, f"{method} {path} was throttled on its first call"
        assert second.status_code == 429, f"{method} {path} is not throttled"


def test_throttle_refuses_a_wrong_token_too(client):
    """The budget is spent before the token is compared, so guessing is throttled either way."""
    rate_limit.current_admin().limit = 1
    wrong = {"X-Admin-Token": "not-the-token"}

    assert client.get("/api/admin/keys", headers=wrong).status_code == 403
    assert client.get("/api/admin/keys", headers=wrong).status_code == 429


def test_admin_health_is_never_throttled(client):
    """It is the liveness probe, and it discloses only whether the surface is enabled."""
    rate_limit.current_admin().limit = 1
    client.get("/api/admin/keys", headers=HEADERS)

    assert client.get("/api/admin/health").status_code == 200
    assert client.get("/api/admin/health").status_code == 200


def test_default_budget_still_allows_a_full_batch_mint(client):
    """The budget is per request, not per key: minting 250 keys is one call."""
    response = client.post("/api/admin/keys", json={"count": 250}, headers=HEADERS)
    assert response.status_code == 200
    assert response.json()["count"] == 250


def test_mint_failure_is_reported_not_spun_on(client, monkeypatch):
    """A key allocation that cannot find a free key must fail, not loop inside the handler."""
    monkeypatch.setattr(db, "get_key", lambda key: {"api_key": key})

    response = client.post("/api/admin/keys", json={"count": 1}, headers=HEADERS)
    assert response.status_code == 507
    assert "unique key" in response.json()["detail"].lower()
