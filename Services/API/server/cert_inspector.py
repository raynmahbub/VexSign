#!/usr/bin/env python3
"""Certificate / provisioning-profile status checker (browser + API).

    GET  /Tools/cert-check              the page (parses locally in the browser)
    POST /api/Tools/cert/inspect        optional server-side parse of an upload
    GET  /api/Tools/cert/revoked-list   the curated local revocation list

What it answers
    * Is this profile still inside its validity window, and for how long?
    * Which team / App ID / platform does it belong to?
    * Does it provision every device (`ProvisionsAllDevices`) or a fixed UDID list?
    * Which entitlements does it grant, and does it carry `get-task-allow`?
    * For a public certificate: subject, issuer, validity and SHA-1/SHA-256
      fingerprints.

What it deliberately does **not** do
    * It never accepts a `.p12`, a password or a private key. The endpoint has no
      password parameter at all, so there is nothing to leak.
    * It does not query Apple. "Revoked" here means "listed in the curated
      `Services/API/server/data/revoked_certs.json` on this deployment"; absence from that list
      is reported as *unknown*, never as *valid*.
    * Reading a provisioning profile is not CMS signature verification: the plist
      is extracted from the signed blob and parsed, which proves nothing about who
      signed it.

Only the standard library is required. If `cryptography` is installed, public
certificates (`.cer`/`.pem`) are fully parsed too; otherwise they still get
fingerprints and a note.
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import plistlib
from datetime import datetime, timezone
from typing import Any

from fastapi import APIRouter, File, HTTPException, Request, UploadFile

import web_chrome

router = APIRouter()

REVOKED_LIST_PATH = os.path.join(os.path.dirname(__file__), "data", "revoked_certs.json")

# Interesting entitlement keys the app's own dashboard calls out.
NOTABLE_ENTITLEMENTS = [
    "application-identifier",
    "get-task-allow",
    "aps-environment",
    "keychain-access-groups",
    "com.apple.developer.team-identifier",
    "com.apple.security.application-groups",
    "com.apple.developer.icloud-container-identifiers",
    "com.apple.developer.networking.networkextension",
    "dynamic-codesigning",
]

MAX_UPLOAD_BYTES = 4 * 1024 * 1024  # profiles and certificates are tiny


# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------

def extract_plist(data: bytes) -> bytes | None:
    """Pull the embedded XML plist out of a CMS-signed blob (or plain plist)."""
    start = data.find(b"<?xml")
    end = data.find(b"</plist>")
    if start == -1 or end == -1 or end < start:
        return None
    return data[start : end + len(b"</plist>")]


def parse_profile(data: bytes) -> dict[str, Any]:
    """Parse a `.mobileprovision` into the report the page renders."""
    blob = extract_plist(data)
    if blob is None:
        raise ValueError("No plist found — this does not look like a provisioning profile.")
    try:
        payload = plistlib.loads(blob)
    except Exception as exc:  # plistlib raises several types on malformed input
        raise ValueError(f"The embedded plist could not be parsed: {exc}") from exc
    if not isinstance(payload, dict):
        raise ValueError("The embedded plist is not a dictionary.")

    created = payload.get("CreationDate")
    expires = payload.get("ExpirationDate")
    now = datetime.now(timezone.utc)

    status = "unknown"
    days_remaining: int | None = None
    if isinstance(expires, datetime):
        expiry = expires if expires.tzinfo else expires.replace(tzinfo=timezone.utc)
        days_remaining = int((expiry - now).total_seconds() // 86_400)
        if expiry <= now:
            status = "expired"
        elif days_remaining <= 7:
            status = "critical"
        elif days_remaining <= 30:
            status = "expiring"
        else:
            status = "valid"

    entitlements = payload.get("Entitlements") or {}
    if not isinstance(entitlements, dict):
        entitlements = {}

    devices = payload.get("ProvisionedDevices")
    if not isinstance(devices, list):
        devices = []

    notable: dict[str, Any] = {}
    for key in NOTABLE_ENTITLEMENTS:
        if key in entitlements:
            notable[key] = entitlements[key]
    # Anything PPQ-ish is reported verbatim rather than interpreted.
    for key, value in entitlements.items():
        if "ppq" in str(key).lower():
            notable[key] = value

    team = payload.get("TeamIdentifier")
    if isinstance(team, list):
        team = ", ".join(str(item) for item in team) or None

    report: dict[str, Any] = {
        "kind": "provisioning-profile",
        "name": payload.get("Name"),
        "uuid": payload.get("UUID"),
        "appIDName": payload.get("AppIDName"),
        "teamName": payload.get("TeamName"),
        "teamIdentifier": team,
        "platform": payload.get("Platform"),
        "created": created.isoformat() if isinstance(created, datetime) else None,
        "expires": expires.isoformat() if isinstance(expires, datetime) else None,
        "daysRemaining": days_remaining,
        "timeToLive": payload.get("TimeToLive"),
        "status": status,
        "provisionsAllDevices": bool(payload.get("ProvisionsAllDevices", False)),
        "isXcodeManaged": bool(payload.get("IsXcodeManaged", False)),
        "deviceCount": len(devices),
        "entitlementCount": len(entitlements),
        "entitlementKeys": sorted(str(key) for key in entitlements),
        "notable": notable,
        "applicationIdentifier": entitlements.get("application-identifier"),
        "sha256": hashlib.sha256(data).hexdigest(),
    }
    return report


def _pem_to_der(data: bytes) -> bytes | None:
    text = data.decode("utf-8", errors="ignore")
    if "-----BEGIN" not in text:
        return None
    lines = [line.strip() for line in text.splitlines() if line.strip() and not line.strip().startswith("-----")]
    try:
        return base64.b64decode("".join(lines))
    except Exception:
        return None


def parse_certificate(data: bytes) -> dict[str, Any]:
    """Public certificate report. Full detail needs the optional `cryptography`."""
    der = _pem_to_der(data) or (data if data[:1] == b"\x30" else None)
    if der is None:
        raise ValueError("Not a PEM or DER certificate.")

    report: dict[str, Any] = {
        "kind": "certificate",
        "sha1": hashlib.sha1(data if _pem_to_der(data) is None else der).hexdigest(),
        "sha256": hashlib.sha256(der).hexdigest(),
        "encoding": "pem" if _pem_to_der(data) is not None else "der",
        "sizeBytes": len(der),
    }

    try:
        from cryptography import x509  # optional dependency
    except ImportError:
        report["detail"] = "Install `cryptography` on the server for subject/issuer/validity parsing."
        return report

    try:
        cert = x509.load_der_x509_certificate(der)
    except Exception as exc:
        raise ValueError(f"Certificate could not be parsed: {exc}") from exc

    now = datetime.now(timezone.utc)
    not_after = cert.not_valid_after_utc
    not_before = cert.not_valid_before_utc
    days_remaining = int((not_after - now).total_seconds() // 86_400)
    if not_after <= now:
        status = "expired"
    elif days_remaining <= 7:
        status = "critical"
    elif days_remaining <= 30:
        status = "expiring"
    else:
        status = "valid"

    is_ca = False
    try:
        basic = cert.extensions.get_extension_for_class(x509.BasicConstraints)
        is_ca = bool(basic.value.ca)
    except x509.ExtensionNotFound:
        pass

    report.update(
        {
            "subject": cert.subject.rfc4514_string(),
            "issuer": cert.issuer.rfc4514_string(),
            "serialNumber": str(cert.serial_number),
            "notBefore": not_before.isoformat(),
            "notAfter": not_after.isoformat(),
            "daysRemaining": days_remaining,
            "status": status,
            "isCA": is_ca,
            "signatureAlgorithm": cert.signature_algorithm_oid._name,  # noqa: SLF001 - no public accessor
            "publicKeyBits": getattr(cert.public_key(), "key_size", None),
            "sha1": hashlib.sha1(der).hexdigest(),
        }
    )
    return report


# ---------------------------------------------------------------------------
# Revocation list (curated, local, honest)
# ---------------------------------------------------------------------------

def revoked_list() -> list[dict[str, Any]]:
    if not os.path.exists(REVOKED_LIST_PATH):
        return []
    try:
        with open(REVOKED_LIST_PATH, encoding="utf-8") as handle:
            entries = json.load(handle)
    except (OSError, ValueError):
        return []
    return entries if isinstance(entries, list) else []


def check_revocation(sha1: str | None, sha256: str | None) -> dict[str, Any]:
    """Look the fingerprints up in the curated list.

    Never returns "not revoked" — absence only means *this deployment has no
    record of it*, which is not evidence about Apple's state.
    """
    sha1 = (sha1 or "").lower()
    sha256 = (sha256 or "").lower()
    for entry in revoked_list():
        if (sha1 and entry.get("sha1", "").lower() == sha1) or (
            sha256 and entry.get("sha256", "").lower() == sha256
        ):
            return {
                "listed": True,
                "status": "revoked",
                "label": entry.get("label"),
                "reported": entry.get("reported"),
                "note": entry.get("note", "Listed in this deployment's revoked_certs.json."),
            }
    return {
        "listed": False,
        "status": "unknown",
        "note": "Not in this deployment's local list. That is not proof the certificate is unrevoked.",
    }


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@router.get("/api/Tools/cert/revoked-list")
def api_revoked_list() -> dict:
    entries = revoked_list()
    return {"count": len(entries), "entries": entries, "source": "Services/API/server/data/revoked_certs.json"}


@router.post("/api/Tools/cert/inspect")
async def api_inspect(file: UploadFile = File(...)) -> dict:
    filename = (file.filename or "").lower()
    if filename.endswith((".p12", ".pfx")):
        raise HTTPException(
            status_code=422,
            detail="Upload a .mobileprovision or a public .cer/.pem instead. This checker never takes a "
            "certificate bundle or a password.",
        )

    data = await file.read(MAX_UPLOAD_BYTES + 1)
    if len(data) > MAX_UPLOAD_BYTES:
        raise HTTPException(status_code=413, detail="File is larger than 4 MiB.")
    if not data:
        raise HTTPException(status_code=422, detail="The upload was empty.")

    report: dict[str, Any] | None = None
    if extract_plist(data) is not None:
        try:
            report = parse_profile(data)
        except ValueError as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc
    else:
        try:
            report = parse_certificate(data)
        except ValueError as exc:
            raise HTTPException(
                status_code=422,
                detail=f"{exc} Upload a .mobileprovision, a public .cer/.pem — never a .p12.",
            ) from exc

    report["filename"] = file.filename
    report["revocation"] = check_revocation(report.get("sha1"), report.get("sha256"))
    return report


@router.get("/Tools/cert-check")
def cert_check_page(request: Request):
    body = """
  <div class="card">
    <div class="drop" id="drop">
      <strong>Drop a provisioning profile here</strong>
      <p class="muted" style="margin:0.4rem 0 0">
        <code>.mobileprovision</code> · <code>.cer</code> · <code>.pem</code><br>
        The file is parsed in your browser — nothing is uploaded unless you press
        <em>Analyse on this server</em>.
      </p>
      <div class="row" style="justify-content:center;margin-top:0.8rem">
        <button class="btn secondary" id="pick">Choose file…</button>
        <input type="file" id="picker" accept=".mobileprovision,.cer,.pem,.crt,.der" hidden>
      </div>
    </div>
    <p class="muted">Never upload a <code>.p12</code> or a password. This tool reads public
      provisioning data only, and the server endpoint has no password field.</p>
  </div>

  <div class="card" id="result" hidden>
    <div class="row" style="justify-content:space-between">
      <h2 style="margin:0" id="result-title">Result</h2>
      <span id="badge"></span>
    </div>
    <table id="facts"></table>
    <div id="entitlements"></div>
    <div class="row" style="margin-top:0.8rem">
      <button class="btn" id="server-check">Analyse on this server</button>
      <span class="muted">Sends the file to this deployment for the same parse (and the local revocation lookup).</span>
    </div>
    <div id="server-result"></div>
  </div>

  <div class="card">
    <h2>How to read the result</h2>
    <ul class="muted" style="margin:0">
      <li><strong>Valid</strong> — inside the profile's own validity window. That says nothing about
        revocation.</li>
      <li><strong>Revoked / unknown</strong> — only the curated list on this deployment is consulted.
        Apple is never queried, so an unlisted certificate is reported as <em>unknown</em>.</li>
      <li><strong>Provisions all devices</strong> — an enterprise/in-house style profile; a fixed
        device list means development/ad-hoc distribution.</li>
      <li><strong>get-task-allow</strong> — present on development profiles, absent on distribution
        ones; the app uses it to decide whether JIT-style debugging entitlements apply.</li>
    </ul>
  </div>
"""

    scripts = """
<script>
const $ = (id) => document.getElementById(id);
let currentFile = null;

const STATUS = {
  valid:    ['ok', 'Valid'],
  expiring: ['warn', 'Expiring soon'],
  critical: ['bad', 'Expires within a week'],
  expired:  ['bad', 'Expired'],
  unknown:  ['idle', 'Unknown']
};

function badge(status) {
  const [cls, label] = STATUS[status] || STATUS.unknown;
  return `<span class="pill ${cls}">${label}</span>`;
}

function rows(pairs) {
  return pairs.filter(p => p[1] !== null && p[1] !== undefined && p[1] !== '')
    .map(p => `<tr><th>${esc(p[0])}</th><td>${esc(p[1])}</td></tr>`).join('');
}

// --- minimal XML plist reader -------------------------------------------------
function parsePlistNode(node) {
  const tag = node.tagName;
  if (tag === 'dict') {
    const out = {};
    const children = [...node.children];
    for (let i = 0; i < children.length; i += 2) {
      if (children[i].tagName === 'key') out[children[i].textContent] = parsePlistNode(children[i + 1]);
    }
    return out;
  }
  if (tag === 'array') return [...node.children].map(parsePlistNode);
  if (tag === 'string') return node.textContent;
  if (tag === 'integer' || tag === 'real') return Number(node.textContent);
  if (tag === 'date') return node.textContent;
  if (tag === 'true') return true;
  if (tag === 'false') return false;
  if (tag === 'data') return node.textContent.trim();
  return null;
}

function profileFromBytes(bytes) {
  const text = new TextDecoder('latin1').decode(bytes);
  const start = text.indexOf('<?xml');
  const end = text.indexOf('</plist>');
  if (start === -1 || end === -1) throw new Error('No embedded plist — is this a provisioning profile?');
  const xml = new DOMParser().parseFromString(text.slice(start, end + 8), 'application/xml');
  const root = xml.querySelector('plist > dict');
  if (!root) throw new Error('The embedded plist has no dictionary.');
  return parsePlistNode(root);
}

function daysUntil(iso) {
  if (!iso) return null;
  const then = new Date(iso);
  if (isNaN(then)) return null;
  return Math.floor((then - new Date()) / 86400000);
}

function statusFor(iso) {
  const days = daysUntil(iso);
  if (days === null) return 'unknown';
  if (days < 0) return 'expired';
  if (days <= 7) return 'critical';
  if (days <= 30) return 'expiring';
  return 'valid';
}

async function sha256Hex(bytes) {
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return [...new Uint8Array(digest)].map(b => b.toString(16).padStart(2, '0')).join('');
}

async function analyse(file) {
  currentFile = file;
  const bytes = new Uint8Array(await file.arrayBuffer());
  $('result').hidden = false;
  $('server-result').innerHTML = '';
  $('result-title').textContent = file.name;

  let report;
  try {
    const plist = profileFromBytes(bytes);
    const entitlements = plist.Entitlements || {};
    const devices = plist.ProvisionedDevices || [];
    report = {
      kind: 'provisioning-profile',
      status: statusFor(plist.ExpirationDate),
      title: plist.Name || 'Provisioning profile',
      facts: [
        ['Profile name', plist.Name],
        ['UUID', plist.UUID],
        ['App ID name', plist.AppIDName],
        ['Application identifier', entitlements['application-identifier']],
        ['Team', [plist.TeamName, (plist.TeamIdentifier || []).join(', ')].filter(Boolean).join(' · ')],
        ['Platform', (plist.Platform || []).join(', ')],
        ['Created', plist.CreationDate],
        ['Expires', plist.ExpirationDate + ` (${daysUntil(plist.ExpirationDate)} days)`],
        ['Time to live', plist.TimeToLive ? plist.TimeToLive + ' days' : null],
        ['Provisions all devices', plist.ProvisionsAllDevices ? 'Yes (enterprise / in-house)' : 'No'],
        ['Provisioned devices', devices.length],
        ['Xcode managed', plist.IsXcodeManaged ? 'Yes' : 'No'],
        ['Entitlements', Object.keys(entitlements).length],
        ['get-task-allow', 'get-task-allow' in entitlements ? String(entitlements['get-task-allow']) : null],
        ['SHA-256', await sha256Hex(bytes)]
      ],
      entitlementKeys: Object.keys(entitlements).sort()
    };
  } catch (error) {
    report = {
      kind: 'certificate',
      status: 'unknown',
      title: file.name,
      facts: [
        ['Note', 'Not a provisioning profile — parsed in the browser only for its fingerprint.'],
        ['Size', bytes.length + ' bytes'],
        ['SHA-256', await sha256Hex(bytes)]
      ],
      entitlementKeys: []
    };
  }

  $('badge').innerHTML = badge(report.status);
  $('facts').innerHTML = rows(report.facts);
  $('entitlements').innerHTML = report.entitlementKeys.length
    ? `<p class="muted" style="margin:0.8rem 0 0.3rem">Entitlement keys</p><pre>${esc(report.entitlementKeys.join('\\n'))}</pre>`
    : '';
}

$('pick').addEventListener('click', () => $('picker').click());
$('picker').addEventListener('change', (event) => { if (event.target.files[0]) analyse(event.target.files[0]); });

const drop = $('drop');
['dragenter', 'dragover'].forEach(name => drop.addEventListener(name, (event) => {
  event.preventDefault(); drop.classList.add('hot');
}));
['dragleave', 'drop'].forEach(name => drop.addEventListener(name, (event) => {
  event.preventDefault(); drop.classList.remove('hot');
}));
drop.addEventListener('drop', (event) => {
  const file = event.dataTransfer.files[0];
  if (file) analyse(file);
});

$('server-check').addEventListener('click', async () => {
  if (!currentFile) return;
  if (/\\.p12$|\\.pfx$/i.test(currentFile.name)) {
    $('server-result').innerHTML = '<p class="issue error">Pick a .mobileprovision or public certificate — never a .p12.</p>';
    return;
  }
  const form = new FormData();
  form.append('file', currentFile);
  $('server-result').innerHTML = '<p class="muted">Working…</p>';
  try {
    const response = await fetch('/api/Tools/cert/inspect', { method: 'POST', body: form });
    const data = await response.json();
    if (!response.ok) throw new Error(data.detail || response.statusText);
    const pairs = Object.entries(data)
      .filter(([key]) => !['notable', 'entitlementKeys', 'revocation', 'kind', 'filename'].includes(key))
      .map(([key, value]) => [key, Array.isArray(value) ? value.join(', ') : (typeof value === 'object' ? JSON.stringify(value) : value)]);
    $('server-result').innerHTML =
      `<p style="margin:0.8rem 0 0.3rem"><strong>Server parse</strong> ${badge(data.status)}</p>` +
      `<table>${rows(pairs)}</table>` +
      `<p class="muted" style="margin:0.6rem 0 0.2rem">Revocation lookup</p>` +
      `<p class="issue ${data.revocation.listed ? 'error' : 'note'}">${esc(data.revocation.note)}${data.revocation.label ? ' — ' + esc(data.revocation.label) : ''}</p>`;
  } catch (error) {
    $('server-result').innerHTML = `<p class="issue error">${esc(error.message)}</p>`;
  }
});
</script>
"""
    return web_chrome.page(
        "Certificate Status Checker",
        body,
        request,
        subtitle="Validity window, team, entitlements and device scope — no private keys, no Apple queries.",
        scripts=scripts,
    )
