#!/usr/bin/env python3
"""UDID grabber — the browser half of "what is this device's UDID?".

    GET  /tools/udid                        the page (one session per page load)
    GET  /api/tools/udid/profile?token=…    the enrolment .mobileconfig
    POST /api/udid/callback?token=…         where the device posts its UDID
    GET  /api/tools/udid/session/{token}    the page polls this for the result

How it works
    The profile is a standard *Profile Service* payload (`PayloadType =
    "Profile Service"`) pointing back at this server. iOS asks for the requested
    device attributes, then POSTs a signed plist to the callback URL; the UDID is
    read out of that plist and shown on the page that created the session.

Privacy / limits
    * Sessions live in process memory only, expire after ``SESSION_TTL_SECONDS``
      and are capped at ``MAX_SESSIONS`` (oldest evicted first). Nothing touches
      the database or the disk, and no UDID is logged.
    * The generated profile is **unsigned** — iOS will say so. Signing it with
      your own certificate removes the warning and is the only change needed for
      a production deployment.
    * A token is a bearer secret: whoever holds the URL sees the UDID posted to
      it. Treat the link like a password and let it expire.
"""

from __future__ import annotations

import plistlib
import threading
import uuid
from collections import OrderedDict
from datetime import datetime, timezone
from typing import Any
from urllib.parse import urlencode

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import Response

import request_base
import web_chrome

router = APIRouter()

SESSION_TTL_SECONDS = 15 * 60
MAX_SESSIONS = 200

# What the device is asked to report. iOS ignores attributes it does not have
# (IMEI on a Wi-Fi iPad, for example).
DEVICE_ATTRIBUTES = [
    "DEVICE_NAME",
    "DEVICE_UDID",
    "PRODUCT",
    "SERIAL",
    "VERSION",
    "IMEI",
    "MEID",
]

_sessions: "OrderedDict[str, dict[str, Any]]" = OrderedDict()
_lock = threading.Lock()


# ---------------------------------------------------------------------------
# Sessions
# ---------------------------------------------------------------------------

def _now() -> float:
    return datetime.now(timezone.utc).timestamp()


def create_session() -> str:
    token = uuid.uuid4().hex
    with _lock:
        _prune_locked()
        while len(_sessions) >= MAX_SESSIONS:
            _sessions.popitem(last=False)
        _sessions[token] = {
            "created": _now(),
            "status": "waiting",
            "device": {},
        }
        _sessions.move_to_end(token)
    return token


def get_session(token: str) -> dict[str, Any] | None:
    with _lock:
        _prune_locked()
        return _sessions.get(token)


def record_device(token: str, attributes: dict[str, Any]) -> bool:
    with _lock:
        _prune_locked()
        session = _sessions.get(token)
        if session is None:
            return False
        session["status"] = "received"
        session["device"] = attributes
        session["received"] = _now()
        _sessions.move_to_end(token)
        return True


def _prune_locked() -> None:
    cutoff = _now() - SESSION_TTL_SECONDS
    for token in [key for key, value in _sessions.items() if value["created"] < cutoff]:
        _sessions.pop(token, None)


# ---------------------------------------------------------------------------
# Profile
# ---------------------------------------------------------------------------

def build_profile(callback_url: str, organization: str = "VexSign", description: str = "") -> bytes:
    """Unsigned Profile Service payload that asks iOS to report its UDID."""
    payload_uuid = str(uuid.uuid4()).upper()
    profile = {
        "PayloadContent": {
            "URL": callback_url,
            "DeviceAttributes": list(DEVICE_ATTRIBUTES),
        },
        "PayloadDescription": description
        or "Sends this device's UDID back to the page that created it. Remove the profile afterwards.",
        "PayloadDisplayName": "VexSign UDID",
        "PayloadIdentifier": f"com.vexsign.udid.{payload_uuid.lower()}",
        "PayloadOrganization": organization,
        "PayloadRemovalDisallowed": False,
        "PayloadType": "Profile Service",
        "PayloadUUID": payload_uuid,
        "PayloadVersion": 1,
    }
    return plistlib.dumps(profile, fmt=plistlib.FMT_XML)


def parse_device_attributes(body: bytes) -> dict[str, Any]:
    """Read the device attributes out of the (signed) plist iOS posts back."""
    start = body.find(b"<?xml")
    end = body.find(b"</plist>")
    if start == -1 or end == -1 or end < start:
        raise ValueError("The device response contained no plist.")
    payload = plistlib.loads(body[start : end + len(b"</plist>")])
    if not isinstance(payload, dict):
        raise ValueError("The device response plist is not a dictionary.")

    attributes = {key: value for key, value in payload.items() if key in DEVICE_ATTRIBUTES}
    if "DEVICE_UDID" not in attributes:
        raise ValueError("The device response carried no UDID.")
    return attributes


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@router.get("/api/tools/udid/profile")
def udid_profile(request: Request, token: str, name: str = "VexSign UDID") -> Response:
    if get_session(token) is None:
        raise HTTPException(status_code=404, detail="That session expired. Reload the UDID page for a new one.")

    base = request_base.base_url(request)
    callback = f"{base}/api/udid/callback?{urlencode({'token': token})}"
    data = build_profile(callback, organization=(name or "VexSign")[:60])
    return Response(
        content=data,
        media_type="application/x-apple-aspen-config",
        headers={"Content-Disposition": 'attachment; filename="VexSign-UDID.mobileconfig"'},
    )


@router.post("/api/udid/callback")
async def udid_callback(request: Request, token: str) -> dict:
    """Where iOS posts the signed attribute plist.

    iOS sends the body as raw (CMS-signed) bytes, so the raw request is parsed
    rather than a decoded form. No UDID is logged.
    """
    body = await request.body()
    if not body:
        raise HTTPException(status_code=422, detail="Empty device response.")

    try:
        attributes = parse_device_attributes(body)
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc

    if not record_device(token, attributes):
        raise HTTPException(
            status_code=410,
            detail="The session that created this profile has expired; the UDID was discarded.",
        )
    return {"status": "ok"}


@router.get("/api/tools/udid/session/{token}")
def udid_session(token: str) -> dict:
    session = get_session(token)
    if session is None:
        return {"status": "expired"}
    remaining = max(0, int(SESSION_TTL_SECONDS - (_now() - session["created"])))
    return {
        "status": session["status"],
        "expiresIn": remaining,
        "device": session["device"],
    }


@router.get("/tools/udid")
def udid_page(request: Request):
    token = create_session()
    body = f"""
  <div class="card">
    <h2>Read this device's UDID</h2>
    <ol class="muted" style="margin:0;padding-left:1.1rem;line-height:1.9">
      <li>Open this page <strong>on the iPhone or iPad</strong> whose UDID you need.</li>
      <li>Tap <em>Download profile</em>, then go to
        <strong>Settings → Profile Downloaded → Install</strong>. iOS will warn that the
        profile is unsigned — that is expected for a self-hosted checker.</li>
      <li>Return to this tab. The UDID appears below automatically.</li>
      <li>Remove the profile afterwards (Settings → General → VPN &amp; Device Management).</li>
    </ol>
    <div class="row" style="margin-top:0.9rem">
      <a class="btn" id="download" href="/api/tools/udid/profile?token={token}">Download profile</a>
      <span class="pill idle" id="state">Waiting for the device…</span>
      <span class="muted" id="countdown"></span>
    </div>
  </div>

  <div class="card" id="result" hidden>
    <h2>Device</h2>
    <table id="facts"></table>
    <div class="row" style="margin-top:0.8rem">
      <button class="btn" id="copy">Copy UDID</button>
      <span class="muted">Paste it into the developer portal, or into a profile that needs a device list.</span>
    </div>
  </div>

  <div class="card">
    <h2>What this does and does not do</h2>
    <ul class="muted" style="margin:0">
      <li>The profile is a standard <em>Profile Service</em> payload; it grants no entitlements and
        installs nothing. Removing it undoes everything.</li>
      <li>Sessions are kept in memory for {SESSION_TTL_SECONDS // 60} minutes and are never written to disk or logged.
        Reload the page for a fresh session.</li>
      <li>Anyone holding this page's URL can read the UDID posted to it — do not share the link.</li>
      <li>Sign the generated profile with your own certificate to drop the iOS "unsigned" warning.</li>
    </ul>
  </div>
"""

    scripts = (
        """
<script>
const TOKEN = '__TOKEN__';
const SESSION_SECONDS = __TTL__;
const $ = (id) => document.getElementById(id);
let deadline = Date.now() + SESSION_SECONDS * 1000;

function rows(pairs) {
  return pairs.filter(p => p[1] !== undefined && p[1] !== null && p[1] !== '')
    .map(p => `<tr><th>${esc(p[0])}</th><td>${esc(p[1])}</td></tr>`).join('');
}

function setState(text, cls) {
  const state = $('state');
  state.className = 'pill ' + cls;
  state.textContent = text;
}

async function poll() {
  try {
    const response = await fetch('/api/tools/udid/session/' + TOKEN, { cache: 'no-store' });
    const data = await response.json();
    if (data.status === 'received') {
      setState('Received', 'ok');
      $('countdown').textContent = '';
      $('result').hidden = false;
      $('facts').innerHTML = rows([
        ['UDID', `<code>${esc(data.device.DEVICE_UDID)}</code>`],
        ['Device', data.device.PRODUCT],
        ['Name', data.device.DEVICE_NAME],
        ['iOS version', data.device.VERSION],
        ['Serial', data.device.SERIAL],
        ['IMEI', data.device.IMEI],
        ['MEID', data.device.MEID]
      ]);
      $('copy').addEventListener('click', async () => {
        await navigator.clipboard.writeText(data.device.DEVICE_UDID);
        $('copy').textContent = 'Copied';
      });
      return;
    }
    if (data.status === 'expired') { setState('Session expired — reload', 'bad'); return; }
    setState('Waiting for the device…', 'idle');
  } catch (error) {
    setState('Cannot reach the server', 'bad');
  }
  setTimeout(poll, 2000);
}

setInterval(() => {
  const left = Math.max(0, Math.round((deadline - Date.now()) / 1000));
  $('countdown').textContent = left ? `expires in ${Math.floor(left / 60)}m ${left % 60}s` : 'expired';
}, 1000);

poll();
</script>
"""
        .replace("__TOKEN__", token)
        .replace("__TTL__", str(SESSION_TTL_SECONDS))
    )
    return web_chrome.page(
        "UDID Grabber",
        body,
        request,
        subtitle="One-time enrolment profile; nothing is stored on this server.",
        scripts=scripts,
    )
