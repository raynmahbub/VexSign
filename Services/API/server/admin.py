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

Everything below lives in `db.py` (the same SQLite table the app-facing
`/api/validate` flow uses), so admin actions take effect instantly.

Authentication is deliberately simple (one bearer header, constant-time
compare) because this server already runs behind Render/TLS and the admin
surface is turned off unless the operator opts in.
"""

import os
import secrets

import tempfile
from pathlib import Path

from fastapi import APIRouter, File, Form, Header, HTTPException, UploadFile
from pydantic import BaseModel

import db
import repo_store
from repo_store import RepoError

router = APIRouter(prefix="/api/admin")

ADMIN_TOKEN = os.environ.get("ADMIN_TOKEN", "").strip()

# Keep the 403 body vague: revealing whether the token matched could help an
# attacker distinguish "route disabled" from "token found".


def is_valid_admin_token(x_admin_token: str | None) -> bool:
    """Non-raising token check (e.g. for deciding what `/` may reveal)."""
    if not ADMIN_TOKEN or not x_admin_token:
        return False
    try:
        return secrets.compare_digest(x_admin_token, ADMIN_TOKEN)
    except TypeError:  # non-ASCII input blows up compare_digest
        return False


def _require_admin(x_admin_token: str | None):
    if not ADMIN_TOKEN:
        raise HTTPException(status_code=403, detail="Admin API is disabled.")
    if not is_valid_admin_token(x_admin_token):
        raise HTTPException(status_code=403, detail="Invalid admin token.")


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
    return {"enabled": bool(ADMIN_TOKEN)}


@router.post("/keys")
def mint_keys(body: MintBody, x_admin_token: str | None = Header(default=None, alias="X-Admin-Token")):
    """Mint fresh keys. Body: {"count": 1}."""
    _require_admin(x_admin_token)

    count = body.validated_count()
    keys = []
    for _ in range(count):
        while True:
            key = "VEX-" + "-".join(
                "".join(secrets.choice(db.KEY_ALPHABET) for _ in range(4)) for _ in range(3)
            )
            if db.get_key(key) is None:
                break
        db.add_key(key)
        keys.append(key)

    return {"count": len(keys), "keys": keys}


@router.get("/keys")
def list_keys(x_admin_token: str | None = Header(default=None, alias="X-Admin-Token")):
    """List every key and its state (fresh / used / disabled) — the same
    inventory CLI `keygen.py list` prints."""
    _require_admin(x_admin_token)

    with db.connect() as conn:
        rows = conn.execute(
            "SELECT api_key, used, device_uuid, disabled, created_at FROM keys ORDER BY created_at DESC"
        ).fetchall()

    return {
        "count": len(rows),
        "keys": [
            {
                "key": row["api_key"],
                "status": "disabled" if row["disabled"] else ("used" if row["used"] else "fresh"),
                "device_uuid": row["device_uuid"],
                "created_at": row["created_at"],
            }
            for row in rows
        ],
    }


def _return_key_or_404(key: str) -> str:
    """Validate that a key exists before any admin mutation (mirror of
    keygen.py's "No such key" guard)."""
    if db.get_key(key) is None:
        raise HTTPException(status_code=404, detail="No such key.")
    return key


@router.post("/keys/disable")
def disable_key(
    body: dict, x_admin_token: str | None = Header(default=None, alias="X-Admin-Token")
):
    """Administratively disable a key (app will show the 403 disabled message)."""
    _require_admin(x_admin_token)
    key = _return_key_or_404(str(body.get("key", "")).strip().upper())
    db.set_key_disabled(key, True)
    return {"ok": True, "key": key, "disabled": True}


@router.post("/keys/enable")
def enable_key(
    body: dict, x_admin_token: str | None = Header(default=None, alias="X-Admin-Token")
):
    """Re-enable a previously disabled key."""
    _require_admin(x_admin_token)
    key = _return_key_or_404(str(body.get("key", "")).strip().upper())
    db.set_key_disabled(key, False)
    return {"ok": True, "key": key, "disabled": False}


@router.post("/keys/reset")
def reset_key(
    body: dict, x_admin_token: str | None = Header(default=None, alias="X-Admin-Token")
):
    """Unbind a consumed key and make it redeemable again."""
    _require_admin(x_admin_token)
    key = _return_key_or_404(str(body.get("key", "")).strip().upper())
    db.reset_key(key)
    return {"ok": True, "key": key, "reset": True}


@router.post("/keys/revoke")
def revoke_key(
    body: dict, x_admin_token: str | None = Header(default=None, alias="X-Admin-Token")
):
    """Permanently delete a key."""
    _require_admin(x_admin_token)
    key = _return_key_or_404(str(body.get("key", "")).strip().upper())
    db.delete_key(key)
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
def list_apps(x_admin_token: str | None = Header(default=None, alias="X-Admin-Token")):
    _require_admin(x_admin_token)
    return {"apps": [app.to_dict() for app in repo_store.store.apps()]}


@router.post("/apps")
def upload_app(
    file: UploadFile = File(...),
    developer: str | None = Form(default=None),
    subtitle: str | None = Form(default=None),
    description: str | None = Form(default=None),
    category: str | None = Form(default=None),
    x_admin_token: str | None = Header(default=None, alias="X-Admin-Token"),
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

    return {"status": "ok", "app": app.to_dict()}


@router.delete("/apps/{bundle_identifier}")
def delete_app(
    bundle_identifier: str,
    x_admin_token: str | None = Header(default=None, alias="X-Admin-Token"),
):
    _require_admin(x_admin_token)
    if not repo_store.store.remove(bundle_identifier):
        raise HTTPException(status_code=404, detail="No such app in the source.")
    return {"status": "ok", "removed": bundle_identifier}
