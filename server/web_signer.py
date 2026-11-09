#!/usr/bin/env python3
"""Browser signing console — a web UI for the app's on-device signer.

VexSign signs on the phone. What it never had was a *browser* page to drive that,
which is what this adds: point it at the phone's Web Manager address, drop in an
IPA, and the signed IPA comes back as a download.

    GET  /tools/signer            the page
    POST /api/tools/sign/proxy    read-only proxy for GET /api/{status,library,updates}
    POST /api/tools/sign/sign     stream an IPA to the phone, stream the signed IPA back

Why a proxy instead of calling the phone directly from the page? The Web Manager
has no CORS headers, so a page on one origin cannot reach `http://phone:8000`
on another — and adding `Access-Control-Allow-Credentials` to a server that
accepts Basic auth would be worse than the proxy. Relaying keeps the browser
call same-origin and lets this deployment add its own guardrails.

Security posture, deliberately narrow:

* The phone must be reachable **from this server**. Self-host on your LAN (or a
  tailnet) or the relay cannot see the phone. A public deployment cannot reach a
  phone behind NAT — that is by design, not a bug.
* Targets are restricted to private / loopback / link-local / CGNAT addresses by
  default, so this endpoint cannot be used to probe arbitrary hosts. Set
  `VEXSIGN_ALLOW_PUBLIC_TARGETS=1` if your Web Manager genuinely has a public
  address (and then put TLS in front of it).
* Nothing is stored: the IPA streams through, the response streams back, and the
  credentials only live for the duration of the request. No logging of tokens.
* Upstream signing is unchanged — this relays `POST /api/sign`, so the phone's
  own certificate, entitlements and queue do the work.
"""

from __future__ import annotations

import base64
import ipaddress
import os
import re
import socket
import time
from typing import Any, Iterator
from urllib.parse import quote, urlparse

import httpx
from fastapi import APIRouter, File, Form, HTTPException, Request, UploadFile
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

from web_chrome import page

router = APIRouter()

# Signing a big IPA on a phone takes a while; the connect timeout stays short so
# a wrong address fails fast instead of hanging the page.
CONNECT_TIMEOUT_SECONDS = 8.0
REQUEST_TIMEOUT_SECONDS = 900.0
CHUNK_BYTES = 256 * 1024
ERROR_SNIPPET_BYTES = 4096

# Read-only Web Manager endpoints the page may proxy. An allowlist, not a
# passthrough: `POST /api/cleanup` must not be reachable from a browser tab.
PROXY_PATHS = ("status", "library", "updates")

# CGNAT space — Tailscale and friends live here, and those hosts are private in
# every sense that matters for this guard.
EXTRA_ALLOWED_NETWORKS = (ipaddress.ip_network("100.64.0.0/10"),)

_SAFE_FILENAME = re.compile(r"[^A-Za-z0-9._-]+")


# ---------------------------------------------------------------------------\
# Target guarding
# ---------------------------------------------------------------------------

def allow_public_targets() -> bool:
    return (os.environ.get("VEXSIGN_ALLOW_PUBLIC_TARGETS") or "").strip().lower() in {
        "1",
        "true",
        "yes",
        "on",
    }


def _is_local_address(address: ipaddress.IPv4Address | ipaddress.IPv6Address) -> bool:
    if address.is_private or address.is_loopback or address.is_link_local:
        return True
    return any(address in network for network in EXTRA_ALLOWED_NETWORKS)


def target_guard_error(raw: str) -> str | None:
    """Return a human-readable refusal reason, or None if the target is allowed."""
    url = (raw or "").strip()
    if not url:
        return "Enter the Web Manager address, e.g. http://192.168.1.20:8000."

    parsed = urlparse(url if "//" in url else f"//{url}")
    if parsed.scheme not in ("http", "https"):
        return "Only http:// and https:// addresses are accepted."
    host = parsed.hostname or ""
    if not host:
        return "That address has no hostname."

    if allow_public_targets():
        return None

    try:
        # A literal IP skips DNS entirely; a name is resolved first so the guard
        # applies to what would actually be connected to.
        infos = socket.getaddrinfo(host, parsed.port or (443 if parsed.scheme == "https" else 80))
        addresses = {ipaddress.ip_address(info[4][0]) for info in infos}
    except (socket.gaierror, OSError, ValueError):
        return f"'{host}' did not resolve."

    if not addresses:
        return f"'{host}' did not resolve."

    for address in addresses:
        if not _is_local_address(address):
            return (
                f"'{host}' resolves to {address}, which is not a private address. "
                "This relay only talks to local networks unless "
                "VEXSIGN_ALLOW_PUBLIC_TARGETS is set."
            )
    return None


def normalised_base(raw: str) -> str:
    url = (raw or "").strip()
    if "//" not in url:
        url = f"http://{url}"
    return url.rstrip("/")


def basic_auth_header(username: str, password: str) -> str | None:
    """Build the header directly.

    `httpx.Client.build_request()` has no `auth` argument (it moved to `send()`
    in 0.23), and computing it here keeps the streaming path working on any
    httpx version rather than depending on which release is installed.
    """
    if not username.strip():
        return None
    raw = f"{username}:{password}".encode("utf-8")
    return "Basic " + base64.b64encode(raw).decode("ascii")


def _headers(token: str, username: str = "", password: str = "") -> dict[str, str]:
    headers = {"Accept": "application/json"}
    if token.strip():
        headers["X-VexSign-Token"] = token.strip()
    authorization = basic_auth_header(username, password)
    if authorization:
        headers["Authorization"] = authorization
    return headers


def _make_client() -> httpx.Client:
    """Factory so tests can substitute an httpx.MockTransport."""
    return httpx.Client(
        timeout=httpx.Timeout(REQUEST_TIMEOUT_SECONDS, connect=CONNECT_TIMEOUT_SECONDS),
        follow_redirects=True,
    )


def _relay_error(status_code: int, detail: str) -> HTTPException:
    """Map an upstream failure onto something a page can show."""
    if 400 <= status_code < 500:
        return HTTPException(status_code=status_code, detail=detail)
    return HTTPException(status_code=502, detail=f"The phone returned {status_code}: {detail}")


# ---------------------------------------------------------------------------\
# Routes
# ---------------------------------------------------------------------------

class ProxyBody(BaseModel):
    baseURL: str
    path: str = "status"
    username: str = ""
    password: str = ""
    token: str = ""


@router.post("/api/tools/sign/proxy")
def api_proxy(body: ProxyBody) -> dict[str, Any]:
    refusal = target_guard_error(body.baseURL)
    if refusal:
        raise HTTPException(status_code=422, detail=refusal)

    path = body.path.strip().strip("/")
    if path.startswith("api/"):
        path = path[4:]
    if path not in PROXY_PATHS:
        raise HTTPException(
            status_code=422,
            detail=f"'{body.path}' is not a readable endpoint. Allowed: {', '.join(PROXY_PATHS)}.",
        )

    url = f"{normalised_base(body.baseURL)}/api/{path}"

    started = time.monotonic()
    try:
        with _make_client() as client:
            response = client.get(
                url, headers=_headers(body.token, body.username, body.password)
            )
    except httpx.ConnectError:
        raise HTTPException(status_code=502, detail=f"Could not reach {url}. Is the Web Manager running?")
    except httpx.TimeoutException:
        raise HTTPException(status_code=504, detail=f"{url} did not answer in time.")
    except httpx.HTTPError as error:
        raise HTTPException(status_code=502, detail=f"Could not reach {url}: {error}")

    latency_ms = int((time.monotonic() - started) * 1000)
    if response.status_code != 200:
        raise _relay_error(response.status_code, response.text[:ERROR_SNIPPET_BYTES] or "empty response")

    try:
        payload = response.json()
    except ValueError:
        raise HTTPException(status_code=502, detail=f"{url} did not return JSON.")

    return {
        "path": path,
        "latencyMs": latency_ms,
        "status": response.status_code,
        "data": payload,
    }


@router.post("/api/tools/sign/sign")
def api_sign(
    request: Request,
    file: UploadFile = File(...),
    baseURL: str = Form(...),
    username: str = Form(""),
    password: str = Form(""),
    token: str = Form(""),
):
    refusal = target_guard_error(baseURL)
    if refusal:
        raise HTTPException(status_code=422, detail=refusal)

    url = f"{normalised_base(baseURL)}/api/sign"
    headers = {"Content-Type": "application/octet-stream"}
    if token.strip():
        headers["X-VexSign-Token"] = token.strip()
    authorization = basic_auth_header(username, password)
    if authorization:
        headers["Authorization"] = authorization

    original = (file.filename or "app.ipa").strip() or "app.ipa"
    stem = _SAFE_FILENAME.sub("-", original.rsplit("/", 1)[-1]).strip("-") or "app.ipa"
    if stem.lower().endswith(".ipa"):
        stem = stem[:-4]
    out_name = f"Signed-{stem}.ipa"

    client = _make_client()
    try:
        upstream = client.build_request("POST", url, content=file.file, headers=headers)
        response = client.send(upstream, stream=True)
    except httpx.ConnectError:
        client.close()
        raise HTTPException(status_code=502, detail=f"Could not reach {url}. Is the Web Manager running?")
    except httpx.TimeoutException:
        client.close()
        raise HTTPException(status_code=504, detail=f"{url} did not answer in time.")
    except httpx.HTTPError as error:
        client.close()
        raise HTTPException(status_code=502, detail=f"Could not reach {url}: {error}")

    if response.status_code != 200:
        # `Response.read()` takes no length argument, so cap by chunk instead.
        detail = next(iter(response.iter_bytes(ERROR_SNIPPET_BYTES)), b"").decode("utf-8", "replace")
        response.close()
        client.close()
        raise _relay_error(
            response.status_code,
            detail.strip() or "the phone rejected the upload",
        )

    def chunks() -> Iterator[bytes]:
        try:
            for chunk in response.iter_bytes(CHUNK_BYTES):
                if chunk:
                    yield chunk
        finally:
            response.close()
            client.close()

    return StreamingResponse(
        chunks(),
        media_type="application/octet-stream",
        headers={"Content-Disposition": f'attachment; filename="{quote(out_name)}"'},
    )


# ---------------------------------------------------------------------------\
# Page
# ---------------------------------------------------------------------------

PAGE_SCRIPT = """
<script>
const $ = (id) => document.getElementById(id);
const log = (text, kind) => {
  const line = document.createElement('div');
  line.className = 'issue ' + (kind || 'note');
  line.textContent = text;
  $('log').prepend(line);
};
const target = () => ({
  baseURL: $('base').value.trim(),
  username: $('user').value.trim(),
  password: $('pass').value,
  token: $('token').value
});

async function connect() {
  $('connect').disabled = true;
  try {
    const response = await fetch('/api/tools/sign/proxy', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(Object.assign({ path: 'status' }, target()))
    });
    const body = await response.json();
    if (!response.ok) throw new Error(body.detail || response.statusText);
    const s = body.data;
    const days = s.certDaysRemaining === null || s.certDaysRemaining === undefined ? '?' : s.certDaysRemaining;
    const pill = s.certValid ? (days <= 3 ? 'warn' : 'ok') : 'bad';
    $('status').innerHTML =
      '<span class="pill ' + pill + '">' + (s.certValid ? 'certificate valid' : 'no usable certificate') + '</span>' +
      ' <span class="muted">' + esc(s.certName || 'unnamed') + ' &middot; ' + esc(days) + ' days left &middot; ' +
      s.installedApps + ' apps &middot; ' + s.signedApps + ' signed &middot; ' + s.pendingUpdates + ' updates &middot; ' +
      body.latencyMs + ' ms</span>';
    $('queue-card').hidden = false;
  } catch (error) {
    log(error.message, 'error');
  } finally {
    $('connect').disabled = false;
  }
}

let queue = [];
let busy = false;

function renderQueue() {
  $('queue').innerHTML = '';
  queue.forEach((job, index) => {
    const row = document.createElement('div');
    row.className = 'row';
    row.style.justifyContent = 'space-between';
    row.innerHTML = '<span>' + (index + 1) + '. ' + esc(job.name) +
      ' <span class="muted">' + (job.size / 1048576).toFixed(1) + ' MB</span></span>' +
      '<span class="pill ' + esc(job.state.pill) + '" id="state-' + index + '">' + esc(job.state.label) + '</span>';
    $('queue').appendChild(row);
  });
}

function setState(index, label, pill) {
  queue[index].state = { label, pill };
  renderQueue();
}

function signOne(job, index) {
  return new Promise((resolve) => {
    const form = new FormData();
    form.append('file', job.file, job.name);
    form.append('baseURL', $('base').value.trim());
    form.append('username', $('user').value.trim());
    form.append('password', $('pass').value);
    form.append('token', $('token').value);

    const xhr = new XMLHttpRequest();
    xhr.open('POST', '/api/tools/sign/sign');
    xhr.responseType = 'blob';
    xhr.upload.onprogress = (event) => {
      if (event.lengthComputable) {
        setState(index, 'uploading ' + Math.round((event.loaded / event.total) * 100) + '%', 'warn');
      }
    };
    xhr.onload = () => {
      if (xhr.status === 200) {
        const link = document.createElement('a');
        link.href = URL.createObjectURL(xhr.response);
        link.download = 'Signed-' + job.name.replace(/\\.ipa$/i, '') + '.ipa';
        document.body.appendChild(link);
        link.click();
        link.remove();
        setState(index, 'signed', 'ok');
        resolve(true);
      } else {
        xhr.response.text().then((text) => {
          let message = text;
          try { message = JSON.parse(text).detail || text; } catch (e) {}
          setState(index, 'failed', 'bad');
          log(job.name + ': ' + message, 'error');
        });
        resolve(false);
      }
    };
    xhr.onerror = () => {
      setState(index, 'failed', 'bad');
      log(job.name + ': the relay could not be reached', 'error');
      resolve(false);
    };
    xhr.send(form);
  });
}

async function runQueue() {
  if (busy) return;
  busy = true;
  $('run').disabled = true;
  let done = 0;
  for (let i = 0; i < queue.length; i += 1) {
    if (queue[i].done) continue;
    setState(i, 'signing…', 'warn');
    const ok = await signOne(queue[i], i);
    queue[i].done = true;
    if (ok) done += 1;
  }
  log('Queue finished: ' + done + ' signed.', done === queue.length ? 'note' : 'warning');
  busy = false;
  $('run').disabled = false;
}

function addFiles(list) {
  Array.from(list).forEach((file) => {
    queue.push({ file, name: file.name, size: file.size, done: false, state: { label: 'queued', pill: 'idle' } });
  });
  renderQueue();
  $('queue-card').hidden = false;
}

document.addEventListener('DOMContentLoaded', () => {
  $('connect').addEventListener('click', connect);
  $('run').addEventListener('click', runQueue);
  $('clear').addEventListener('click', () => { queue = []; renderQueue(); });
  $('picker').addEventListener('change', (event) => addFiles(event.target.files));
  $('browse').addEventListener('click', () => $('picker').click());
  const drop = $('drop');
  ['dragenter', 'dragover'].forEach((name) =>
    drop.addEventListener(name, (event) => { event.preventDefault(); drop.classList.add('hot'); }));
  ['dragleave', 'drop'].forEach((name) =>
    drop.addEventListener(name, (event) => { event.preventDefault(); drop.classList.remove('hot'); }));
  drop.addEventListener('drop', (event) => addFiles(event.dataTransfer.files));
});
</script>
"""


@router.get("/tools/signer")
def signer_page(request: Request):
    body = """
  <div class="card">
    <h2>1. Connect to the phone</h2>
    <div class="grid two">
      <div>
        <label>Web Manager address</label>
        <input id="base" placeholder="http://192.168.1.20:8000" autocomplete="off">
      </div>
      <div><label>API token (optional, if the app has one set)</label><input id="token" type="password" autocomplete="off"></div>
      <div><label>Basic-auth username (optional)</label><input id="user" autocomplete="off"></div>
      <div><label>Basic-auth password (optional)</label><input id="pass" type="password" autocomplete="off"></div>
    </div>
    <p class="muted">Start the Web Manager on the iPhone first
      (<em>Settings → Web Manager</em>). The address is printed there.</p>
    <div class="row">
      <button class="btn" id="connect">Connect</button>
      <span id="status" class="muted"></span>
    </div>
  </div>

  <div class="card" id="queue-card">
    <h2>2. Queue IPAs</h2>
    <div class="drop" id="drop">Drop IPAs here, or
      <button class="btn ghost" id="browse" type="button">browse</button>
      <input type="file" id="picker" accept=".ipa,application/octet-stream" multiple hidden></div>
    <div class="stack" id="queue" style="margin-top:0.7rem"></div>
    <div class="row" style="margin-top:0.7rem">
      <button class="btn" id="run">Sign queue</button>
      <button class="btn secondary" id="clear">Clear</button>
      <span class="muted">Each IPA is streamed to the phone, signed there with its default certificate, and streamed back.</span>
    </div>
  </div>

  <div class="card">
    <h2>Log</h2>
    <div id="log" class="stack"><div class="issue note">Nothing yet.</div></div>
  </div>
"""
    return page(
        "Signer Console",
        body,
        request,
        subtitle="Drive the phone's on-device signer from a browser.",
        scripts=PAGE_SCRIPT,
    )
