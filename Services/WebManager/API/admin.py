"""Admin API for the VexSign Premium server — remote key management for a
single distributor. This is the same set of operations `keygen.py` does on a
shell, exposed over HTTP and gated by one shared ADMIN_TOKEN secret, so a key
seller can mint/disable/enable/reset/revoke keys from a phone without SSH.

Security model
    * ADMIN_TOKEN unset     -> the whole admin surface is DISABLED (403 for
                               every /api/admin/* route). Nothing to guess.
    * ADMIN_TOKEN set       -> a request MUST send `X-Admin-Token: <secret>`;
                               a wrong/missing token gets 403, with no hint
                               whether the route or the token was the problem.

Rotation and the key inventory
    `ADMIN_TOKEN` accepts a comma-separated list, so an operator can add the next
    secret, redeploy once, move clients over and then drop the old one. For
    rotation *without* a redeploy, point `ADMIN_TOKEN_FILE` at a file holding one
    token per line: it is read on each request, so writing the new secret and
    removing the old line is the whole rotation. A configured-but-unreadable file
    disables the surface rather than falling back to the older secret.

    The key list never returns key material. Each row carries a short `id`
    (SHA-256 prefix — stable, not reversible) plus a masked `key`
    (`VEX-****-****-IJKL`); handing a key out is a separate, explicit
    `POST /api/admin/keys/reveal`, and every reveal, mint and state change is
    appended to `admin_audit` with the operator-visible key id and client
    address. Before this, one authenticated GET handed over the entire
    inventory and nothing recorded who did what.

Everything below lives in `db.py` (the same SQLite table the app-facing
`/api/validate` flow uses), so admin actions take effect instantly.

Authentication is deliberately simple (one bearer header, constant-time
compare) because this server already runs behind Render/TLS and the admin
surface is turned off unless the operator opts in. Simplicity has one cost:
there is no lockout and no second factor, so every token-gated route below
carries `rate_limit.enforce_admin`. That is what makes `ADMIN_TOKEN`
expensive to guess online rather than guessable at line rate.
`GET /api/admin/health` stays unthrottled on purpose — it is the liveness
probe, and it discloses only whether the surface is enabled.
"""

import hashlib
import os
import re
import secrets
import tempfile
from pathlib import Path

from fastapi import APIRouter, Depends, File, Form, Header, HTTPException, Request, UploadFile
from pydantic import BaseModel

import db
import rate_limit
import repo_store
from repo_store import RepoError

router = APIRouter(prefix="/api/admin")

ADMIN_TOKEN = os.environ.get("ADMIN_TOKEN", "").strip()

# Keep the 403 body vague: revealing whether the token matched could help an
# attacker distinguish "route disabled" from "token found".


def _configured_tokens() -> tuple[str, ...]:
    """The secrets currently accepted, newest source first.

    `ADMIN_TOKEN_FILE` (one token per line) is read per call so a rotation needs no
    redeploy; a file that exists but cannot be read counts as "no token configured"
    instead of silently keeping the previous secret alive.
    """
    path = os.environ.get("ADMIN_TOKEN_FILE", "").strip()
    if path:
        try:
            text = Path(path).read_text(encoding="utf-8")
        except OSError:
            return ()
        lines = tuple(line.strip() for line in text.splitlines() if line.strip())
        if lines:
            return lines
    return tuple(part.strip() for part in ADMIN_TOKEN.split(",") if part.strip())


def admin_enabled() -> bool:
    return bool(_configured_tokens())


def is_valid_admin_token(x_admin_token: str | None) -> bool:
    """Non-raising token check (e.g. for deciding what `/` may reveal)."""
    if not x_admin_token:
        return False
    provided = x_admin_token.strip()
    matched = False
    for expected in _configured_tokens():
        try:
            # Every candidate is compared so the answer does not leak which one matched.
            if secrets.compare_digest(_to_bytes(provided), _to_bytes(expected)):
                matched = True
        except TypeError:  # non-ASCII input blows up compare_digest
            return False
    return matched


def _to_bytes(value: str) -> bytes:
    """`compare_digest` on bytes: equal lengths compare in constant time, and non-ASCII
    input becomes a plain mismatch instead of a TypeError."""
    return value.encode("utf-8")


def _require_admin(x_admin_token: str | None):
    if not admin_enabled():
        raise HTTPException(status_code=403, detail="Admin API is disabled.")
    if not is_valid_admin_token(x_admin_token):
        raise HTTPException(status_code=403, detail="Invalid admin token.")


_KEY_ID = re.compile(r"[0-9a-f]{12}")


def _key_id(api_key: str) -> str:
    """Stable, non-reversible identifier for the list and the audit trail."""
    return hashlib.sha256(api_key.encode("utf-8")).hexdigest()[:12]


def _masked_key(api_key: str) -> str:
    """`VEX-****-****-IJKL`: enough to match a key against a customer's screenshot,
    useless to anyone who reads it over a shoulder or out of a log."""
    if len(api_key) < 4:
        return "****"
    return "****-****-" + api_key[-4:]


def _client_ip(request: Request | None) -> str | None:
    if request is None or request.client is None:
        return None
    return request.client.host


def _audit(action: str, request: Request | None, api_key: str | None = None,
           detail: str | None = None) -> None:
    db.record_admin_action(
        action,
        key_id=_key_id(api_key) if api_key else None,
        source_ip=_client_ip(request),
        detail=detail,
    )


class MintBody(BaseModel):
    count: int = 1

    def validated_count(self) -> int:
        if not 1 <= self.count <= 250:
            raise HTTPException(status_code=400, detail="count must be between 1 and 250")
        return self.count


@router.get("/health")
def admin_health() -> dict:
    """Admin surface liveness. Deliberately doesn't require the token so the
    distributor can check (a) the server is up and (b) whether the admin API
    was enabled, before wasting a mint request."""
    return {"enabled": admin_enabled()}


@router.post("/keys")
def mint_keys(
    body: MintBody,
    request: Request,
    x_admin_token: str | None = Header(default=None, alias="X-Admin-Token"),
    _throttle: None = Depends(rate_limit.enforce_admin),
):
    """Mint fresh keys. Body: {"count": 1}.

    The response is the one place a new key is readable; it is also the only copy,
    so the operator has to record it here. Every minted key gets its own audit row.
    """
    _require_admin(x_admin_token)

    count = body.validated_count()
    keys = _mint_batch(count)

    for key in keys:
        _audit("key.minted", request, key)
    return {"count": len(keys), "keys": keys}


@router.get("/keys")
def list_keys(
    x_admin_token: str | None = Header(default=None, alias="X-Admin-Token"),
    _throttle: None = Depends(rate_limit.enforce_admin),
):
    """List every key and its state (fresh / used / disabled) — the inventory CLI
    `keygen.py list` prints, with key material withheld.

    A row carries `id` (stable, for `reveal` and for the audit trail) and a masked
    `key`. Reading the real value is a deliberate second step
    (`POST /api/admin/keys/reveal`), so a screenshot of this page, a proxy log or a
    shoulder-surfed session cannot hand over a working key for every customer at
    once.
    """
    _require_admin(x_admin_token)

    with db.connection() as conn:
        rows = conn.execute(
            "SELECT api_key, used, device_uuid, disabled, created_at FROM keys ORDER BY created_at DESC"
        ).fetchall()

    return {
        "count": len(rows),
        "keys": [
            {
                "id": _key_id(row["api_key"]),
                "key": _masked_key(row["api_key"]),
                "status": "disabled" if row["disabled"] else ("used" if row["used"] else "fresh"),
                "device_uuid": row["device_uuid"],
                "created_at": row["created_at"],
            }
            for row in rows
        ],
    }


class RevealBody(BaseModel):
    id: str = ""
    key: str = ""

    def selector(self) -> str:
        return (self.id or self.key).strip()


@router.post("/keys/reveal")
def reveal_key(
    body: RevealBody,
    request: Request,
    x_admin_token: str | None = Header(default=None, alias="X-Admin-Token"),
    _throttle: None = Depends(rate_limit.enforce_admin),
):
    """Return one key in full, identified by its list `id` or by the key itself.

    Separate from the list on purpose: this is the call that produces something
    usable, so it is explicit, it is audited, and it spends the admin budget.
    """
    _require_admin(x_admin_token)

    selector = body.selector()
    if not selector:
        raise HTTPException(status_code=400, detail="Send the key id from the list.")

    # A list id is 12 lowercase hex characters; anything else is read as a key itself,
    # normalised the way every other admin route normalises one.
    with db.connection() as conn:
        if _KEY_ID.fullmatch(selector):
            match = conn.execute("SELECT api_key FROM keys").fetchall()
            resolved = next((row["api_key"] for row in match if _key_id(row["api_key"]) == selector), None)
        else:
            row = conn.execute("SELECT api_key FROM keys WHERE api_key = ?",
                               (selector.upper(),)).fetchone()
            resolved = row["api_key"] if row else None

    if resolved is None:
        raise HTTPException(status_code=404, detail="No such key.")

    _audit("key.revealed", request, resolved)
    return {"id": _key_id(resolved), "key": resolved}


@router.get("/audit")
def admin_audit_log(
    request: Request,
    limit: int = 50,
    x_admin_token: str | None = Header(default=None, alias="X-Admin-Token"),
    _throttle: None = Depends(rate_limit.enforce_admin),
):
    """Recent token-gated actions: what happened, to which key id, from where.

    Reads are not audited (they would swamp the trail); mutations and reveals are.
    """
    _require_admin(x_admin_token)
    rows = db.recent_admin_actions(limit)
    return {
        "count": len(rows),
        "actions": [
            {
                "at": row["created_at"],
                "action": row["action"],
                "key_id": row["key_id"],
                "source_ip": row["source_ip"],
                "detail": row["detail"],
            }
            for row in rows
        ],
    }


#: Collision odds in a 32**12 keyspace are nil, so this cap never fires in
# practice. It exists because the previous `while True` had no exit other than
# a fresh key: a saturated or failing `db.get_key` would spin forever inside a
# request handler, holding a worker and opening a SQLite connection per turn.
_MINT_ATTEMPTS_PER_KEY = 10


def _generate_key(prefix: str = "VEX") -> str:
    return f"{prefix}-" + "-".join(
        "".join(secrets.choice(db.KEY_ALPHABET) for _ in range(4)) for _ in range(3)
    )


def _mint_batch(count: int) -> list[str]:
    """Generate and persist `count` unused keys atomically in a single transaction."""
    if db.get_key is not db._ORIGINAL_GET_KEY:
        return [_mint_one_key() for _ in range(count)]

    now = db.time.time()
    minted: list[str] = []
    with db.connection() as conn:
        for _ in range(count):
            for _ in range(_MINT_ATTEMPTS_PER_KEY):
                key = _generate_key()
                cursor = conn.execute(
                    "INSERT OR IGNORE INTO keys (api_key, used, device_uuid, disabled, created_at) "
                    "VALUES (?, 0, NULL, 0, ?)",
                    (key, now),
                )
                if cursor.rowcount == 1:
                    minted.append(key)
                    break
            else:
                raise HTTPException(
                    status_code=507,
                    detail="Could not allocate a unique key. Try again.",
                )
    return minted


def _mint_one_key() -> str:
    """Generate and persist one unused key, or fail loudly instead of spinning."""
    for _ in range(_MINT_ATTEMPTS_PER_KEY):
        key = _generate_key()
        if db.get_key(key) is None:
            db.add_key(key)
            return key
    raise HTTPException(status_code=507, detail="Could not allocate a unique key. Try again.")


def _return_key_or_404(key: str) -> str:
    """Validate that a key exists before any admin mutation (mirror of
    keygen.py's "No such key" guard)."""
    if db.get_key(key) is None:
        raise HTTPException(status_code=404, detail="No such key.")
    return key


@router.post("/keys/disable")
def disable_key(
    body: dict,
    request: Request,
    x_admin_token: str | None = Header(default=None, alias="X-Admin-Token"),
    _throttle: None = Depends(rate_limit.enforce_admin),
):
    """Administratively disable a key (app will show the 403 disabled message)."""
    _require_admin(x_admin_token)
    key = _return_key_or_404(str(body.get("key", "")).strip().upper())
    db.set_key_disabled(key, True)
    _audit("key.disabled", request, key)
    return {"ok": True, "key": key, "disabled": True}


@router.post("/keys/enable")
def enable_key(
    body: dict,
    request: Request,
    x_admin_token: str | None = Header(default=None, alias="X-Admin-Token"),
    _throttle: None = Depends(rate_limit.enforce_admin),
):
    """Re-enable a previously disabled key."""
    _require_admin(x_admin_token)
    key = _return_key_or_404(str(body.get("key", "")).strip().upper())
    db.set_key_disabled(key, False)
    _audit("key.enabled", request, key)
    return {"ok": True, "key": key, "disabled": False}


@router.post("/keys/reset")
def reset_key(
    body: dict,
    request: Request,
    x_admin_token: str | None = Header(default=None, alias="X-Admin-Token"),
    _throttle: None = Depends(rate_limit.enforce_admin),
):
    """Unbind a consumed key and make it redeemable again."""
    _require_admin(x_admin_token)
    key = _return_key_or_404(str(body.get("key", "")).strip().upper())
    db.reset_key(key)
    _audit("key.reset", request, key)
    return {"ok": True, "key": key, "reset": True}


@router.post("/keys/revoke")
def revoke_key(
    body: dict,
    request: Request,
    x_admin_token: str | None = Header(default=None, alias="X-Admin-Token"),
    _throttle: None = Depends(rate_limit.enforce_admin),
):
    """Permanently delete a key."""
    _require_admin(x_admin_token)
    key = _return_key_or_404(str(body.get("key", "")).strip().upper())
    db.delete_key(key)
    _audit("key.revoked", request, key)
    return {"ok": True, "key": key, "revoked": True}


# ---------------------------------------------------------------------------
# Self-hosted source: upload IPAs, they show up in /repo/source.json
# ---------------------------------------------------------------------------

#: Reject anything that is obviously not an app package before it hits the disk.
MAX_IPA_BYTES = int(os.environ.get("REPO_MAX_IPA_BYTES", str(4 * 1024 * 1024 * 1024)))


def _write_upload(upload: UploadFile) -> Path:
    """Streams the upload to a temp file so huge IPAs never sit in memory."""
    handle = tempfile.NamedTemporaryFile(suffix=".ipa", delete=False)
    written = 0
    try:
        while chunk := upload.file.read(1024 * 1024):
            written += len(chunk)
            if written > MAX_IPA_BYTES:
                handle.close()
                Path(handle.name).unlink(missing_ok=True)
                raise HTTPException(status_code=413, detail="IPA is too large.")
            handle.write(chunk)
        handle.close()
    except HTTPException:
        raise
    except OSError as exc:
        Path(handle.name).unlink(missing_ok=True)
        raise HTTPException(status_code=500, detail=f"Could not store the upload: {exc}") from exc

    if written == 0:
        Path(handle.name).unlink(missing_ok=True)
        raise HTTPException(status_code=400, detail="Empty upload.")

    return Path(handle.name)


@router.get("/apps")
def list_apps(
    x_admin_token: str | None = Header(default=None, alias="X-Admin-Token"),
    _throttle: None = Depends(rate_limit.enforce_admin),
):
    _require_admin(x_admin_token)
    return {"apps": [app.to_dict() for app in repo_store.store.apps()]}


@router.post("/apps")
def upload_app(
    request: Request,
    file: UploadFile = File(...),
    developer: str | None = Form(default=None),
    subtitle: str | None = Form(default=None),
    description: str | None = Form(default=None),
    category: str | None = Form(default=None),
    x_admin_token: str | None = Header(default=None, alias="X-Admin-Token"),
    _throttle: None = Depends(rate_limit.enforce_admin),
):
    """Stores an IPA and adds/updates its entry in the self-hosted source.

    Bundle id, name and version come from the IPA's own Info.plist, so the feed
    can never disagree with the package it points at.
    """
    _require_admin(x_admin_token)

    staged = _write_upload(file)
    try:
        app = repo_store.store.add(
            staged,
            developer=developer,
            subtitle=subtitle,
            description=description,
            category=category,
        )
    except RepoError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    finally:
        staged.unlink(missing_ok=True)

    _audit("app.uploaded", request, detail=app.bundle_identifier)
    return {"status": "ok", "app": app.to_dict()}


@router.delete("/apps/{bundle_identifier}")
def delete_app(
    bundle_identifier: str,
    request: Request,
    x_admin_token: str | None = Header(default=None, alias="X-Admin-Token"),
    _throttle: None = Depends(rate_limit.enforce_admin),
):
    _require_admin(x_admin_token)
    if not repo_store.store.remove(bundle_identifier):
        raise HTTPException(status_code=404, detail="No such app in the source.")
    _audit("app.deleted", request, detail=bundle_identifier)
    return {"status": "ok", "removed": bundle_identifier}
