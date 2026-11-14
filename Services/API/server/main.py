#!/usr/bin/env python3
"""VexSign Premium API — drop-in backend for the app's premium key flow.

Implements the exact contract `PremiumManager` (App/iOS/VexSign/Backend/Observable)
expects:

    POST /api/validate    header: X-API-Key, JSON body: {"device_uuid": "..."}
        -> 200 {"urls": [{"url": "..."}]}      key consumed + bound to device
        -> 401 {"detail": "..."}               unknown / already-used key
        -> 403 {"detail": "..."}               disabled key

    GET  /api/urls        header: vexSignUUID
        -> 200 {"urls": [{"url": "..."}]}      device has an activation
        -> 401 {"detail": "..."}               nothing registered for device

    GET  /api/health      -> {"status": "ok"}

Out of the box, a successful redemption returns this server's built-in demo
premium source (GET /repo/premium.json, gated by the same device/key headers),
so the whole flow can be tested with zero extra hosting. For real content,
either set PREMIUM_REPO_URLS (feeds hosted elsewhere) or drop your own
AltStore-v1 feed at premium.json / PREMIUM_FEED_FILE (served here).

Environment variables:
    PREMIUM_REPO_URLS   Comma-separated feed URLs returned on redemption.
    PREMIUM_FEED_FILE   Your feed JSON served at /repo/premium.json
                        (default: premium.json next to main.py, re-read per
                        request — content edits apply without a restart).
    SEED_KEYS           Comma-separated keys (re)created on boot, idempotent.
                        Lets hosts without shell access (Render free tier)
                        restore keys after a redeploy wiped the DB.
    PUBLIC_BASE_URL     Public base URL override for generated feed URLs.
    VEXSIGN_DB         SQLite path (default: vexsign.db next to main.py).

Run:
    pip install -r requirements.txt
    python keygen.py create -n 1
    uvicorn main:app --host 0.0.0.0 --port 8000
"""

import html
import json
import os
from contextlib import asynccontextmanager

from fastapi import FastAPI, Header, HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse, Response
from pydantic import BaseModel

import db
import admin
import repo_store
import request_base
import web_tools
from admin import router as admin_router
from web_tools import router as web_tools_router

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

def _env_repo_urls() -> list[str]:
    raw = os.environ.get("PREMIUM_REPO_URLS", "")
    return [url.strip() for url in raw.split(",") if url.strip()]


INVALID_KEY_DETAIL = "Invalid API key. The key does not exist or has already been used."
DISABLED_KEY_DETAIL = "This API key has been disabled."
NO_ACTIVATION_DETAIL = "No premium access is registered for this device ID."


def _seed_keys() -> None:
    """Idempotently add SEED_KEYS on boot (comma-separated, upper-cased).

    Keys that already exist are left untouched (device bindings preserved),
    so this doubles as the recovery path after a redeploy wiped the DB on a
    host without persistent storage or shell access.
    """
    raw = os.environ.get("SEED_KEYS", "")
    added = 0
    for key in (k.strip().upper() for k in raw.split(",") if k.strip()):
        if db.get_key(key) is None:
            db.add_key(key)
            added += 1
    if added:
        print(f"[vexsign] seeded {added} key(s) from SEED_KEYS", flush=True)


@asynccontextmanager
async def lifespan(_: FastAPI):
    _seed_keys()
    yield


app = FastAPI(
    title="VexSign Premium API",
    docs_url=None,
    redoc_url=None,
    openapi_url=None,
    lifespan=lifespan,
)

# Distributor admin API (token-gated; disabled when ADMIN_TOKEN is unset).
app.include_router(admin_router)

# Browser tools: repository creator, certificate status checker, UDID grabber.
# Public by design (no keys, no private data); see web_tools.py.
app.include_router(web_tools_router)


@app.exception_handler(RequestValidationError)
async def _validation_error_handler(_: Request, exc: RequestValidationError) -> JSONResponse:
    """Return a plain-string `detail` like every other error from this API.

    FastAPI's default 422 body is `{"detail": [...]}` (a list), which the app's
    `VexSignAPI.ErrorResponse` (string `detail`) cannot decode — the user would
    only ever see the generic fallback message. Join the complaints into one
    readable string instead.
    """
    parts = []
    for error in exc.errors():
        where = ".".join(str(bit) for bit in error.get("loc", []) if bit != "body")
        message = error.get("msg", "invalid value")
        parts.append(f"{where}: {message}" if where else message)
    # Lowercase "detail" matches FastAPI's HTTPException shape used by every
    # other error from this API (and what the app decodes).
    return JSONResponse(
        status_code=422, content={"detail": "; ".join(parts) or "Request validation failed."}
    )


class ValidateBody(BaseModel):
    device_uuid: str


def _first_forwarded(value: str | None, default: str) -> str:
    """First entry of a (possibly chained) forwarding header.

    Kept as a local alias: the implementation moved to `request_base` so the
    browser tools build their callback URLs the exact same way.
    """
    return request_base._first_forwarded(value, default)


def _base_url(request: Request) -> str:
    """Public base URL, respecting reverse-proxy forwarding headers.

    `PUBLIC_BASE_URL` (env) wins over header inference — set it when the
    proxy doesn't forward X-Forwarded-Host/X-Forwarded-Proto (e.g. e2b
    sandbox previews), so the URLs handed to the app are always the public
    ones it can actually reach.
    """
    return request_base.base_url(request)


def _urls_payload(request: Request, count: int) -> dict:
    """Shape the app decodes into `VexSignAPI.URLsResponse`. Must be non-empty."""
    urls = _env_repo_urls() or [f"{_base_url(request)}/repo/premium.json"]
    return {"urls": [{"url": url} for url in urls[:count]]}


# ---------------------------------------------------------------------------
# App-facing endpoints (the /api prefix must match apiBaseURL in the app)
# ---------------------------------------------------------------------------

@app.get("/api/health")
def health() -> dict:
    return {"status": "ok"}


@app.post("/api/validate")
def validate(
    body: ValidateBody,
    request: Request,
    x_api_key: str | None = Header(default=None, alias="X-API-Key"),
) -> dict:
    # Keys are stored upper-cased (see keygen/admin minting); normalise here so a
    # key typed in lower case or with stray whitespace still redeems.
    key = (x_api_key or "").strip().upper()
    if not key:
        raise HTTPException(status_code=401, detail=INVALID_KEY_DETAIL)

    device_uuid = (body.device_uuid or "").strip()
    if not device_uuid:
        raise HTTPException(status_code=422, detail="device_uuid is required.")

    row = db.get_key(key)

    if row is None:
        raise HTTPException(status_code=401, detail=INVALID_KEY_DETAIL)

    if row["disabled"]:
        raise HTTPException(status_code=403, detail=DISABLED_KEY_DETAIL)

    # Keys are single-use and device-bound. Re-validating with the same device
    # is allowed (idempotent) so reinstall/restore flows stay smooth; a
    # different device gets the exact message the app shows for burned keys.
    if row["used"]:
        if row["device_uuid"] != device_uuid:
            raise HTTPException(status_code=401, detail=INVALID_KEY_DETAIL)
        return _urls_payload(request, count=25)

    if not row["used"]:
        # Atomically claim the key to prevent double-spending / race conditions.
        if not db.consume_key(key, device_uuid):
            raise HTTPException(status_code=401, detail=INVALID_KEY_DETAIL)

    return _urls_payload(request, count=25)


@app.get("/api/urls")
def urls(
    request: Request,
    vexsign_uuid: str | None = Header(default=None, alias="vexSignUUID"),
) -> dict:
    vexsign_uuid = (vexsign_uuid or "").strip()
    if not vexsign_uuid or not db.device_has_activation(vexsign_uuid):
        raise HTTPException(status_code=401, detail=NO_ACTIVATION_DETAIL)

    return _urls_payload(request, count=25)


# ---------------------------------------------------------------------------
# Gated premium source (your feed file, or the built-in demo as fallback)
# ---------------------------------------------------------------------------

def _require_premium_access(
    vexsign_uuid: str | None,
    x_api_key: str | None,
) -> None:
    """The app attaches `vexSignUUID` (always) and `X-API-Key` (once the key
    is persisted) when fetching URLs on premium hosts — mirror that here."""
    if vexsign_uuid and db.device_has_activation(vexsign_uuid.strip()):
        return
    if x_api_key and db.key_allows_downloads(x_api_key.strip().upper()):
        return
    raise HTTPException(status_code=401, detail=NO_ACTIVATION_DETAIL)


def _local_feed() -> dict | None:
    """Your real feed, if present: PREMIUM_FEED_FILE (env) or a premium.json
    next to main.py. Read on every request so edits apply without a restart.
    Template: premium.example.json (exact shape ASRepository decodes)."""
    path = os.environ.get("PREMIUM_FEED_FILE") or os.path.join(
        os.path.dirname(__file__), "premium.json"
    )
    if not os.path.exists(path):
        return None
    try:
        with open(path, encoding="utf-8") as f:
            feed = json.load(f)
    except (OSError, ValueError) as exc:
        raise HTTPException(status_code=500, detail=f"Premium feed file is invalid: {exc}")
    if not isinstance(feed, dict) or not feed.get("apps"):
        raise HTTPException(
            status_code=500,
            detail="Premium feed must be a JSON object with a non-empty 'apps' array.",
        )
    return feed


@app.get("/repo/premium.json")
def premium_repo(
    request: Request,
    vexsign_uuid: str | None = Header(default=None, alias="vexSignUUID"),
    x_api_key: str | None = Header(default=None, alias="X-API-Key"),
) -> dict:
    _require_premium_access(vexsign_uuid, x_api_key)

    feed = _local_feed()
    if feed is not None:
        return feed

    base = _base_url(request)

    # Minimal AltStore v1 source (exact shape `ASRepository` decodes):
    # identifier + name + non-empty apps[]; every app needs name, bundleIdentifier
    # and iconURL. Replace the demo app with your real IPA entries (see README).
    return {
        "name": "VexSign Premium",
        "identifier": "com.vexsign.premium",
        "subtitle": "Your private premium source",
        "iconURL": f"{base}/static/icon.png",
        "sourceURL": f"{base}/repo/premium.json",
        "apps": [
            {
                "name": "Premium Demo",
                "bundleIdentifier": "com.vexsign.premium.demo",
                "developerName": "VexSign",
                "subtitle": "Premium works — replace me with your real apps",
                "version": "1.0",
                "versionDate": "2026-09-19T00:00:00Z",
                "versionDescription": "Demo entry served by your own VexSign backend.",
                "iconURL": f"{base}/static/icon.png",
            }
        ],
    }


# ---------------------------------------------------------------------------
# Self-hosted source (public): add /repo/source.json as a source in VexSign or
# any AltStore-family client. Fill it with `POST /api/admin/apps` (admin token).
# ---------------------------------------------------------------------------

@app.get("/repo/source.json")
def self_hosted_source(request: Request) -> dict:
    """AltStore v1 source built from the uploaded IPAs (see repo_store.py)."""
    return repo_store.source_feed(_base_url(request))


@app.get("/repo/appdata", include_in_schema=False)
def self_hosted_appdata(request: Request) -> Response:
    """Legacy AltServer XML feed, for clients that never moved to JSON."""
    return Response(
        content=repo_store.appdata_xml(_base_url(request)),
        media_type="application/xml",
    )


@app.get("/static/apps/{filename}", include_in_schema=False)
def self_hosted_ipa(filename: str) -> FileResponse:
    """Streams one stored IPA. Only files inside the store are reachable."""
    apps_root = repo_store.apps_dir().resolve()
    candidate = (apps_root / filename).resolve()
    if not str(candidate).startswith(str(apps_root) + os.sep) or not candidate.is_file():
        raise HTTPException(status_code=404, detail="No such IPA.")
    return FileResponse(candidate, media_type="application/octet-stream", filename=filename)


@app.get("/static/icon.png", include_in_schema=False)
def icon() -> FileResponse:
    return FileResponse(os.path.join(os.path.dirname(__file__), "static", "icon.png"))


def _public_endpoints() -> list[str]:
    return [
        "POST /api/validate",
        "GET /api/urls",
        "GET /api/health",
        "GET /repo/premium.json",
        "GET /repo/source.json     (self-hosted source, add it in VexSign)",
        "GET /repo/appdata         (legacy AltServer XML feed)",
        "GET /tools                (browser tools: repo creator, cert check, UDID)",
    ]


def _admin_endpoints() -> list[str]:
    return [
        "GET /api/admin/health",
        "POST /api/admin/keys        (mint)",
        "GET /api/admin/keys         (list)",
        "POST /api/admin/keys/disable|enable|reset|revoke",
        "POST /api/admin/apps        (upload an IPA into /repo/source.json)",
        "GET /api/admin/apps         (list the self-hosted source)",
        "DELETE /api/admin/apps/{bundle_identifier}",
    ]


def _landing_page(base: str, endpoints: list[str], show_admin: bool) -> str:
    """Human-friendly status page for browsers (API clients keep the JSON).

    `base` is derived from request headers, so everything interpolated is
    escaped — a malicious Host header must not become stored XSS here.
    """
    safe_base = html.escape(base, quote=True)
    items = "\n".join(f"      <li><code>{html.escape(e)}</code></li>" for e in endpoints)
    admin_note = (
        "<p class=\"muted\">Admin endpoints are hidden without a valid "
        "<code>X-Admin-Token</code>.</p>"
        if not show_admin
        else ""
    )
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>VexSign Premium API</title>
<style>
  :root {{ color-scheme: light dark; }}
  body {{ font-family: -apple-system, system-ui, sans-serif; margin: 0; padding: 2rem 1rem;
         background: #0f0f14; color: #f2f2f5; }}
  @media (prefers-color-scheme: light) {{
    body {{ background: #fafafa; color: #1c1c1e; }}
    code {{ background: #eeeef2 !important; }}
    .card {{ background: #fff !important; border-color: #e5e5ea !important; }}
  }}
  main {{ max-width: 640px; margin: 0 auto; }}
  h1 {{ font-size: 1.6rem; margin-bottom: 0.25rem; }}
  .card {{ background: #17171d; border: 1px solid #2c2c34; border-radius: 12px;
          padding: 1rem 1.25rem; margin: 1rem 0; }}
  code {{ background: #26262e; padding: 0.15rem 0.4rem; border-radius: 6px;
         font-size: 0.85em; word-break: break-all; }}
  ul {{ padding-left: 1.1rem; }} li {{ margin: 0.35rem 0; }}
  .status {{ display: flex; align-items: center; gap: 0.5rem; font-weight: 600; }}
  #dot {{ width: 10px; height: 10px; border-radius: 50%; background: #999; }}
  #dot.ok {{ background: #30d158; }} #dot.bad {{ background: #ff453a; }}
  .muted {{ color: #98989f; font-size: 0.9em; }}
  a {{ color: #c96fad; }}
</style>
</head>
<body>
<main>
  <h1>VexSign Premium API</h1>
  <p class="status"><span id="dot"></span><span id="status">Checking status&hellip;</span></p>
  <div class="card">
    <strong>Add the source in VexSign</strong> (Sources &rarr; Add):
    <p><code>{safe_base}/repo/source.json</code><br>
    <span class="muted">Public self-hosted source. Empty until the first IPA is uploaded.</span></p>
    <p><code>{safe_base}/repo/premium.json</code><br>
    <span class="muted">Gated premium feed &mdash; redeem a key in the app first.</span></p>
  </div>
  <div class="card">
    <strong>Browser tools</strong>
    <p><a href="{safe_base}/tools">/tools</a> &mdash; build a repository feed,
    read a provisioning profile's expiry, or grab a device UDID.
    <span class="muted">Nothing is uploaded or stored; private keys are never accepted.</span></p>
  </div>
  <div class="card">
    <strong>Endpoints</strong>
    <ul>
{items}
    </ul>
    {admin_note}
  </div>
  <p class="muted">VexSign is open source:
  <a href="https://github.com/raynmahbub/VexSign">github.com/raynmahbub/VexSign</a>.
  Keys: @iamSMMH on Telegram.</p>
</main>
<script>
fetch('/api/health').then(r => {{
  const ok = r.ok;
  document.getElementById('dot').className = ok ? 'ok' : 'bad';
  document.getElementById('status').textContent = ok ? 'Online' : 'Degraded';
}}).catch(() => {{
  document.getElementById('dot').className = 'bad';
  document.getElementById('status').textContent = 'Unreachable';
}});
</script>
</body>
</html>
"""


@app.get("/")
def root(
    request: Request,
    x_admin_token: str | None = Header(default=None, alias="X-Admin-Token"),
):
    base = _base_url(request)
    # Only an authenticated admin sees the admin surface here; every visitor
    # used to learn it exists (and that ADMIN_TOKEN is set) from this page.
    show_admin = admin.is_valid_admin_token(x_admin_token)
    endpoints = _public_endpoints() + (_admin_endpoints() if show_admin else [])

    # Browsers get a readable status page; API clients (curl, URLSession,
    # uptime monitors — anything not asking for HTML) keep the exact JSON
    # contract this route always returned.
    if "text/html" in request.headers.get("accept", ""):
        return HTMLResponse(_landing_page(base, endpoints, show_admin))

    return {
        "service": "VexSign Premium API",
        "endpoints": endpoints,
        "appSetting": f'static let apiBaseURL = "{base}/api"  // App/iOS/VexSign/Utilities/VexSignAPI.swift',
    }
