#!/usr/bin/env python3
"""Web-based repository creator.

A browser front-end for the same job the app's **Repository Builder** does:
describe a repository and its apps, lint the result, and export a feed any
AltStore-family client can add. The heavy lifting is shared between the page and
`POST /api/Tools/repo/*` so the browser and the API can never disagree about what
a valid feed looks like:

    POST /api/Tools/repo/validate  lint a draft -> issues[] (error / warning)
    POST /api/Tools/repo/export    draft + format -> source.json / apps.json
    POST /api/Tools/repo/ota       one app -> OTA manifest + itms-services link

The validation rules mirror `App/iOS/VexSign/RepositoryBuilder/RepositoryValidator.swift`
(missing identifiers, insecure URLs, unparseable dates, duplicate screenshots,
duplicate bundle ids) so a feed that passes here also imports cleanly in the app.

Like the app's OTA export, nothing is uploaded or hosted: exporting writes a file
to *your* disk, and the OTA manifest points at whatever HTTPS URL you give it.
"""

from __future__ import annotations

import json
import plistlib
import re
from datetime import datetime, timezone
from typing import Any
from urllib.parse import quote

from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel, Field

import web_chrome

router = APIRouter()

# ---------------------------------------------------------------------------
# Model (field names match the app's RepositoryApp / RepositoryDocument)
# ---------------------------------------------------------------------------

KNOWN_CATEGORIES = [
    "Other",
    "Developer",
    "Utilities",
    "Entertainment",
    "Games",
    "Music",
    "Photo & Video",
    "Social Networking",
    "Productivity",
    "Education",
    "Tweaks",
]

_BUNDLE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")


class RepoApp(BaseModel):
    name: str = ""
    bundleIdentifier: str = ""
    version: str = "1.0"
    versionDate: str = ""
    localizedDescription: str = ""
    iconURL: str = ""
    screenshotURLs: list[str] = Field(default_factory=list)
    downloadURL: str = ""
    size: int = 0
    developerName: str = ""
    category: str = "Other"
    tintColor: str = ""
    subtitle: str = ""


class RepoDraft(BaseModel):
    name: str = "New Repository"
    identifier: str = ""
    subtitle: str = ""
    description: str = ""
    iconURL: str = ""
    sourceURL: str = ""
    website: str = ""
    tintColor: str = ""
    apps: list[RepoApp] = Field(default_factory=list)


class ValidateBody(BaseModel):
    draft: RepoDraft


class ExportBody(BaseModel):
    draft: RepoDraft
    # altstore = inline apps + versions[] (SideStore/VexSign); flat = the shared
    # Feather/ESign-style schema; apps = the companion apps.json array.
    format: str = "altstore"


class OTABody(BaseModel):
    app: RepoApp
    # Where the manifest itself will be reachable over HTTPS. Required because
    # itms-services:// only accepts an https manifest URL; we do not host it.
    manifestURL: str = ""
    displayImageURL: str = ""
    fullSizeImageURL: str = ""


class Issue(BaseModel):
    severity: str  # "error" | "warning"
    message: str
    suggestion: str = ""
    app: str = ""  # app the issue belongs to (empty = repository level)


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

def _is_http_url(value: str) -> bool:
    return value.startswith("http://") or value.startswith("https://")


def _parse_date(value: str) -> datetime | None:
    """Accept the shapes the app writes: ISO-8601 with or without seconds."""
    text = value.strip()
    if not text:
        return None
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed


def validate_draft(draft: RepoDraft) -> list[Issue]:
    """Lint a repository draft. Mirrors `RepositoryValidator.validate`."""
    issues: list[Issue] = []

    def add(severity: str, message: str, suggestion: str = "", app: str = "") -> None:
        issues.append(Issue(severity=severity, message=message, suggestion=suggestion, app=app))

    if not draft.name.strip():
        add("error", "The repository has no name.", "Give the source a display name.")
    if not draft.identifier.strip():
        add("error", "The repository has no identifier.", "Use a reverse-DNS id such as com.example.store.")
    elif not _BUNDLE_ID.match(draft.identifier.strip()):
        add("warning", f"Repository identifier “{draft.identifier}” is not reverse-DNS style.", "Use letters, digits, dots and dashes only.")
    for label, value in (("icon", draft.iconURL), ("source URL", draft.sourceURL), ("website", draft.website)):
        if value and not _is_http_url(value):
            add("error", f"Repository {label} “{value}” is not an http(s) URL.", "URLs must start with https:// (or http://).")
    if draft.sourceURL and draft.sourceURL.startswith("http://"):
        add("warning", "The repository sourceURL is cleartext http.", "iOS blocks cleartext feeds unless ATS exceptions are configured.")

    if not draft.apps:
        add("warning", "The repository has no apps.", "Add at least one app, or the feed will show an empty list.")

    seen_ids: dict[str, int] = {}
    for index, app in enumerate(draft.apps):
        label = app.name.strip() or app.bundleIdentifier.strip() or f"App {index + 1}"
        if not app.name.strip():
            add("error", "App has no name.", "Set the display name.", label)
        if not app.bundleIdentifier.strip():
            add("error", "App has no bundle identifier.", "Use the app's real bundle id, e.g. com.example.app.", label)
        elif not _BUNDLE_ID.match(app.bundleIdentifier.strip()):
            add("error", f"Bundle identifier “{app.bundleIdentifier}” contains invalid characters.", "Letters, digits, dots and dashes only.", label)
        else:
            key = app.bundleIdentifier.strip().lower()
            seen_ids[key] = seen_ids.get(key, 0) + 1

        if not app.version.strip():
            add("error", "App has no version.", "Set the version the IPA reports.", label)
        if not app.downloadURL.strip():
            add("error", "App has no download URL.", "Point at the .ipa over https.", label)
        elif not _is_http_url(app.downloadURL):
            add("error", f"Download URL “{app.downloadURL}” is not an http(s) URL.", "Use an https link to the .ipa.", label)
        elif app.downloadURL.startswith("http://"):
            add("warning", "Download URL is cleartext http.", "iOS refuses cleartext IPA downloads.", label)

        if not app.iconURL.strip():
            add("warning", "App has no icon URL.", "Clients fall back to a placeholder icon.", label)
        elif not _is_http_url(app.iconURL):
            add("error", f"Icon URL “{app.iconURL}” is not an http(s) URL.", "Use an https image URL.", label)

        if app.versionDate.strip() and _parse_date(app.versionDate) is None:
            add("error", f"Version date “{app.versionDate}” is not ISO-8601.", "Use 2026-01-31T12:00:00Z.", label)
        if app.size < 0:
            add("error", "Size cannot be negative.", "Use the IPA size in bytes.", label)
        elif app.size == 0:
            add("warning", "Size is 0.", "Clients show the size next to the app; set the IPA byte count.", label)
        if app.category and app.category not in KNOWN_CATEGORIES:
            add("warning", f"Category “{app.category}” is not a common one.", "Pick one of the known categories for better filtering.", label)

        for shot in app.screenshotURLs:
            if shot and not _is_http_url(shot):
                add("error", f"Screenshot URL “{shot}” is not an http(s) URL.", "Use https image URLs.", label)
        duplicates = len(app.screenshotURLs) - len({s for s in app.screenshotURLs if s})
        if duplicates > 0:
            add("warning", f"{duplicates} duplicate screenshot URL(s).", "Remove the duplicates.", label)

    for bundle_id, count in seen_ids.items():
        if count > 1:
            add("error", f"Bundle identifier “{bundle_id}” appears {count} times.", "One entry per bundle id (use versions[] for history).", bundle_id)

    # Errors first, then warnings, each group in document order.
    order = {"error": 0, "warning": 1}
    return sorted(issues, key=lambda issue: order.get(issue.severity, 2))


# ---------------------------------------------------------------------------
# Export
# ---------------------------------------------------------------------------

def _iso(value: str) -> str:
    parsed = _parse_date(value)
    if parsed is None:
        return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    return parsed.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _app_base(app: RepoApp) -> dict[str, Any]:
    data: dict[str, Any] = {
        "name": app.name.strip(),
        "bundleIdentifier": app.bundleIdentifier.strip(),
        "developerName": app.developerName.strip(),
        "version": app.version.strip(),
        "versionDate": _iso(app.versionDate),
        "versionDescription": app.localizedDescription.strip(),
        "iconURL": app.iconURL.strip(),
        "downloadURL": app.downloadURL.strip(),
        "size": int(app.size or 0),
        "category": app.category.strip() or "Other",
    }
    if app.subtitle.strip():
        data["subtitle"] = app.subtitle.strip()
    if app.screenshotURLs:
        data["screenshotURLs"] = [s for s in app.screenshotURLs if s]
    if app.tintColor.strip():
        data["tintColor"] = app.tintColor.strip()
    return data


def export_altstore(draft: RepoDraft) -> dict[str, Any]:
    """AltStore v1: inline `apps`, each with a `versions` history array."""
    apps = []
    for app in draft.apps:
        entry = _app_base(app)
        entry["versions"] = [
            {
                "version": entry["version"],
                "date": entry["versionDate"],
                "downloadURL": entry["downloadURL"],
                "size": entry["size"],
                "localizedDescription": entry.pop("versionDescription", ""),
            }
        ]
        apps.append(entry)

    source: dict[str, Any] = {
        "name": draft.name.strip() or "VexSign Repository",
        "identifier": draft.identifier.strip() or "com.vexsign.repository",
        "apps": apps,
    }
    for key, value in (
        ("subtitle", draft.subtitle),
        ("description", draft.description),
        ("iconURL", draft.iconURL),
        ("sourceURL", draft.sourceURL),
        ("website", draft.website),
        ("tintColor", draft.tintColor),
    ):
        if value.strip():
            source[key] = value.strip()
    return source


def export_flat(draft: RepoDraft) -> dict[str, Any]:
    """Feather/ESign-style shared schema: no `versions` history."""
    source = export_altstore(draft)
    for app in source["apps"]:
        app.pop("versions", None)
    return source


def export_apps_json(draft: RepoDraft) -> list[dict[str, Any]]:
    """The companion `apps.json` array (apps only, no repository metadata)."""
    return [_app_base(app) for app in draft.apps]


def build_export(draft: RepoDraft, fmt: str) -> dict[str, Any]:
    if fmt == "altstore":
        return {"filename": "source.json", "payload": export_altstore(draft)}
    if fmt == "flat":
        return {"filename": "source.json", "payload": export_flat(draft)}
    if fmt == "apps":
        return {"filename": "apps.json", "payload": export_apps_json(draft)}
    raise HTTPException(status_code=422, detail=f"Unknown export format “{fmt}”. Use altstore, flat or apps.")


# ---------------------------------------------------------------------------
# OTA manifest
# ---------------------------------------------------------------------------

def build_manifest(app: RepoApp, manifest_url: str, display_image: str, full_size_image: str) -> bytes:
    """The software-package plist `itms-services://` points at."""
    asset: dict[str, Any] = {
        "kind": "software-package",
        "url": app.downloadURL.strip(),
    }
    assets: list[dict[str, Any]] = [asset]
    if display_image:
        assets.append({"kind": "display-image", "url": display_image, "needs-shine": True})
    if full_size_image:
        assets.append({"kind": "full-size-image", "url": full_size_image, "needs-shine": True})

    metadata: dict[str, Any] = {
        "bundle-identifier": app.bundleIdentifier.strip() or "com.vexsign.unknown",
        "bundle-version": app.version.strip() or "1.0",
        "kind": "software",
        "title": app.name.strip() or "App",
    }
    if app.subtitle.strip():
        metadata["subtitle"] = app.subtitle.strip()

    payload = {
        "items": [
            {
                "assets": assets,
                "metadata": metadata,
            }
        ]
    }
    return plistlib.dumps(payload, fmt=plistlib.FMT_XML)


def install_link(manifest_url: str) -> str:
    return "itms-services://?action=download-manifest&url=" + quote(manifest_url, safe="")


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@router.post("/api/Tools/repo/validate")
def api_validate(body: ValidateBody) -> dict:
    issues = validate_draft(body.draft)
    return {
        "issues": [issue.model_dump() for issue in issues],
        "errorCount": sum(1 for issue in issues if issue.severity == "error"),
        "warningCount": sum(1 for issue in issues if issue.severity == "warning"),
        "appCount": len(body.draft.apps),
    }


@router.post("/api/Tools/repo/export")
def api_export(body: ExportBody) -> dict:
    exported = build_export(body.draft, body.format)
    issues = validate_draft(body.draft)
    return {
        "filename": exported["filename"],
        "format": body.format,
        "json": json.dumps(exported["payload"], indent=2, ensure_ascii=False),
        "errorCount": sum(1 for issue in issues if issue.severity == "error"),
    }


@router.post("/api/Tools/repo/ota")
def api_ota(body: OTABody) -> dict:
    if not body.app.downloadURL.startswith("https://"):
        raise HTTPException(
            status_code=422,
            detail="The IPA download URL must be https — iOS refuses cleartext OTA installs.",
        )
    if not body.manifestURL.startswith("https://"):
        raise HTTPException(
            status_code=422,
            detail="Give the https URL where you will host this manifest. VexSign does not host it for you.",
        )

    manifest = build_manifest(
        body.app,
        body.manifestURL,
        body.displayImageURL,
        body.fullSizeImageURL,
    )
    return {
        "manifest": manifest.decode("utf-8"),
        "manifestURL": body.manifestURL,
        "installLink": install_link(body.manifestURL),
    }


@router.get("/Tools/repo-creator")
def repo_creator_page(request: Request):
    body = """
  <div class="card">
    <div class="row" style="justify-content:space-between">
      <h2 style="margin:0">Repository</h2>
      <span class="row">
        <button class="btn secondary" id="import-file">Import JSON…</button>
        <input type="file" id="import-picker" accept=".json,application/json" hidden>
        <button class="btn secondary" id="import-url">Import from URL…</button>
        <button class="btn secondary" id="load-sample">Load sample</button>
      </span>
    </div>
    <div class="grid two" style="margin-top:0.6rem">
      <div><label>Name</label><input id="repo-name" value="My Repository"></div>
      <div><label>Identifier</label><input id="repo-identifier" placeholder="com.example.store"></div>
      <div><label>Subtitle</label><input id="repo-subtitle" placeholder="Optional"></div>
      <div><label>Icon URL</label><input id="repo-icon" placeholder="https://…/icon.png"></div>
      <div><label>Source URL (where this feed will be hosted)</label><input id="repo-source-url" placeholder="https://…/source.json"></div>
      <div><label>Website</label><input id="repo-website" placeholder="https://…"></div>
      <div><label>Tint colour</label><input id="repo-tint" placeholder="#c96fad"></div>
      <div><label>Description</label><input id="repo-description" placeholder="Optional"></div>
    </div>
  </div>

  <div class="card">
    <div class="row" style="justify-content:space-between">
      <h2 style="margin:0">Apps <span class="muted" id="app-count"></span></h2>
      <button class="btn" id="add-app">Add app</button>
    </div>
    <div id="apps"></div>
  </div>

  <div class="card">
    <h2>Validate &amp; export</h2>
    <div class="row">
      <button class="btn" id="validate">Validate</button>
      <select id="format" style="width:auto">
        <option value="altstore">AltStore / SideStore (versions[])</option>
        <option value="flat">Flat (Feather / ESign style)</option>
        <option value="apps">apps.json only</option>
      </select>
      <button class="btn secondary" id="export">Export</button>
      <button class="btn ghost" id="ota">OTA manifest…</button>
    </div>
    <div id="issues"></div>
    <pre id="output" hidden></pre>
  </div>

  <div class="card" id="ota-card" hidden>
    <h2>OTA install</h2>
    <p class="muted" style="margin-top:0">Pick an app, then the https URL where you will host the manifest.
      VexSign does not upload anything: the manifest is generated for you to host yourself.</p>
    <div class="grid two">
      <div><label>App</label><select id="ota-app"></select></div>
      <div><label>Manifest URL (https)</label><input id="ota-manifest-url" placeholder="https://your.host/manifest.plist"></div>
      <div><label>Display image (57×57, optional)</label><input id="ota-display" placeholder="https://…/icon.png"></div>
      <div><label>Full-size image (512×512, optional)</label><input id="ota-full" placeholder="https://…/large.png"></div>
    </div>
    <div class="row" style="margin-top:0.6rem">
      <button class="btn" id="ota-build">Generate manifest</button>
      <a class="btn secondary" id="ota-download" hidden download="manifest.plist">Download manifest.plist</a>
    </div>
    <p class="muted">Install link (open it on the device):</p>
    <code id="ota-link"></code>
    <pre id="ota-output" hidden></pre>
  </div>

  <div class="card">
    <h2>Hosting</h2>
    <p class="muted" style="margin:0">Upload the exported <code>source.json</code> plus your IPAs to any
      static HTTPS host (this server's <code>POST /api/admin/apps</code> does it too, reading each IPA's
      own Info.plist), then add the feed URL in VexSign under <em>Sources → Add</em>.</p>
  </div>
"""

    scripts = """
<script>
const $ = (id) => document.getElementById(id);
let apps = [];

const CATEGORIES = ["Other","Developer","Utilities","Entertainment","Games","Music","Photo & Video","Social Networking","Productivity","Education","Tweaks"];

function today() { return new Date().toISOString().replace(/\\.\\d{3}Z$/, 'Z'); }

function appCard(app, index) {
  const options = CATEGORIES.map(c => `<option${c === app.category ? ' selected' : ''}>${c}</option>`).join('');
  return `
  <details class="card" style="margin:0.6rem 0 0" ${index === apps.length - 1 ? 'open' : ''}>
    <summary style="cursor:pointer;font-weight:600">
      ${esc(app.name || 'Untitled app')} <span class="muted">${esc(app.bundleIdentifier || 'no bundle id')}</span>
    </summary>
    <div class="grid two" style="margin-top:0.6rem">
      <div><label>Name</label><input data-f="name" value="${escapeAttr(app.name)}"></div>
      <div><label>Bundle identifier</label><input data-f="bundleIdentifier" value="${escapeAttr(app.bundleIdentifier)}"></div>
      <div><label>Version</label><input data-f="version" value="${escapeAttr(app.version)}"></div>
      <div><label>Version date (ISO-8601)</label><input data-f="versionDate" value="${escapeAttr(app.versionDate)}"></div>
      <div><label>Developer</label><input data-f="developerName" value="${escapeAttr(app.developerName)}"></div>
      <div><label>Subtitle</label><input data-f="subtitle" value="${escapeAttr(app.subtitle)}"></div>
      <div><label>Download URL (.ipa)</label><input data-f="downloadURL" value="${escapeAttr(app.downloadURL)}"></div>
      <div><label>Icon URL</label><input data-f="iconURL" value="${escapeAttr(app.iconURL)}"></div>
      <div><label>Size (bytes)</label><input data-f="size" type="number" min="0" value="${escapeAttr(app.size || 0)}"></div>
      <div><label>Category</label><select data-f="category">${options}</select></div>
      <div><label>Tint colour</label><input data-f="tintColor" value="${escapeAttr(app.tintColor)}"></div>
      <div><label>Screenshot URLs (one per line)</label><textarea data-f="screenshotURLs">${escapeAttr((app.screenshotURLs || []).join('\\n'))}</textarea></div>
    </div>
    <div style="margin-top:0.6rem"><label>Description</label><textarea data-f="localizedDescription">${escapeAttr(app.localizedDescription)}</textarea></div>
    <div class="row" style="margin-top:0.6rem">
      <button class="btn secondary" data-a="duplicate">Duplicate</button>
      <button class="btn ghost" data-a="delete">Delete</button>
    </div>
  </details>`;
}

function escapeAttr(value) {
  // One escaping rule for the whole tool surface: the shared helper also covers
  // '>' and apostrophes, and is what every other tool page uses.
  return esc(value);
}

function render() {
  $('apps').innerHTML = apps.map(appCard).join('') ||
    '<p class="muted" style="margin:0.75rem 0 0">No apps yet.</p>';
  $('app-count').textContent = apps.length ? `(${apps.length})` : '';
  const select = $('ota-app');
  select.innerHTML = apps.map((app, i) =>
    `<option value="${i}">${escapeAttr(app.name || app.bundleIdentifier || 'App ' + (i + 1))}</option>`).join('');
  wireApps();
}

function wireApps() {
  document.querySelectorAll('#apps details').forEach((card, index) => {
    card.querySelectorAll('[data-f]').forEach(field => {
      field.addEventListener('input', () => {
        const key = field.dataset.f;
        let value = field.value;
        if (key === 'screenshotURLs') value = value.split('\\n').map(s => s.trim()).filter(Boolean);
        else if (key === 'size') value = parseInt(value || '0', 10);
        apps[index][key] = value;
      });
    });
    card.querySelectorAll('[data-a]').forEach(button => {
      button.addEventListener('click', () => {
        if (button.dataset.a === 'delete') apps.splice(index, 1);
        else apps.splice(index + 1, 0, JSON.parse(JSON.stringify(apps[index])));
        render();
      });
    });
  });
}

function draft() {
  return {
    name: $('repo-name').value,
    identifier: $('repo-identifier').value,
    subtitle: $('repo-subtitle').value,
    description: $('repo-description').value,
    iconURL: $('repo-icon').value,
    sourceURL: $('repo-source-url').value,
    website: $('repo-website').value,
    tintColor: $('repo-tint').value,
    apps: apps
  };
}

async function postJSON(url, payload) {
  const response = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload)
  });
  if (!response.ok) throw new Error((await response.json()).detail || response.statusText);
  return response.json();
}

function renderIssues(result) {
  const box = $('issues');
  if (!result.issues.length) {
    box.innerHTML = '<p class="issue note">No issues. The feed should import cleanly in VexSign.</p>';
    return;
  }
  box.innerHTML = result.issues.map(issue =>
    `<div class="issue ${issue.severity}"><strong>${issue.severity === 'error' ? 'Error' : 'Warning'}${issue.app ? ' · ' + escapeAttr(issue.app) : ''}</strong><br>${escapeAttr(issue.message)}<br><span class="muted">${escapeAttr(issue.suggestion)}</span></div>`
  ).join('');
}

function download(name, text) {
  const blob = new Blob([text], { type: 'application/json' });
  const link = document.createElement('a');
  link.href = URL.createObjectURL(blob);
  link.download = name;
  link.click();
  URL.revokeObjectURL(link.href);
}

$('add-app').addEventListener('click', () => {
  apps.push({ name: '', bundleIdentifier: '', version: '1.0', versionDate: today(),
              localizedDescription: '', iconURL: '', screenshotURLs: [], downloadURL: '',
              size: 0, developerName: '', category: 'Other', tintColor: '', subtitle: '' });
  render();
});

$('validate').addEventListener('click', async () => {
  try { renderIssues(await postJSON('/api/Tools/repo/validate', { draft: draft() })); }
  catch (error) { $('issues').innerHTML = `<p class="issue error">${esc(error.message)}</p>`; }
});

$('export').addEventListener('click', async () => {
  try {
    const result = await postJSON('/api/Tools/repo/export', { draft: draft(), format: $('format').value });
    $('output').hidden = false;
    $('output').textContent = result.json;
    download(result.filename, result.json);
    renderIssues(await postJSON('/api/Tools/repo/validate', { draft: draft() }));
  } catch (error) { $('issues').innerHTML = `<p class="issue error">${esc(error.message)}</p>`; }
});

$('ota').addEventListener('click', () => { $('ota-card').hidden = !$('ota-card').hidden; });

$('ota-build').addEventListener('click', async () => {
  const app = apps[parseInt($('ota-app').value || '0', 10)];
  if (!app) { alert('Add an app first.'); return; }
  try {
    const result = await postJSON('/api/Tools/repo/ota', {
      app,
      manifestURL: $('ota-manifest-url').value,
      displayImageURL: $('ota-display').value,
      fullSizeImageURL: $('ota-full').value
    });
    $('ota-output').hidden = false;
    $('ota-output').textContent = result.manifest;
    $('ota-link').textContent = result.installLink;
    const link = $('ota-download');
    link.hidden = false;
    link.href = 'data:application/xml;charset=utf-8,' + encodeURIComponent(result.manifest);
  } catch (error) {
    $('ota-output').hidden = false;
    $('ota-output').textContent = error.message;
  }
});

function ingest(text) {
  let parsed;
  try { parsed = JSON.parse(text); } catch (error) { alert('That is not valid JSON: ' + error.message); return; }
  const list = Array.isArray(parsed) ? parsed : (parsed.apps || []);
  if (parsed && !Array.isArray(parsed)) {
    $('repo-name').value = parsed.name || $('repo-name').value;
    $('repo-identifier').value = parsed.identifier || $('repo-identifier').value;
    $('repo-subtitle').value = parsed.subtitle || '';
    $('repo-description').value = parsed.description || '';
    $('repo-icon').value = parsed.iconURL || '';
    $('repo-source-url').value = parsed.sourceURL || '';
    $('repo-website').value = parsed.website || '';
    $('repo-tint').value = parsed.tintColor || '';
  }
  apps = list.map(entry => ({
    name: entry.name || '',
    bundleIdentifier: entry.bundleIdentifier || '',
    version: entry.version || (entry.versions && entry.versions[0] && entry.versions[0].version) || '1.0',
    versionDate: entry.versionDate || (entry.versions && entry.versions[0] && entry.versions[0].date) || today(),
    localizedDescription: entry.localizedDescription || entry.versionDescription || '',
    iconURL: entry.iconURL || '',
    screenshotURLs: entry.screenshotURLs || [],
    downloadURL: entry.downloadURL || (entry.versions && entry.versions[0] && entry.versions[0].downloadURL) || '',
    size: entry.size || 0,
    developerName: entry.developerName || '',
    category: entry.category || 'Other',
    tintColor: entry.tintColor || '',
    subtitle: entry.subtitle || ''
  }));
  render();
}

$('import-file').addEventListener('click', () => $('import-picker').click());
$('import-picker').addEventListener('change', async (event) => {
  const file = event.target.files[0];
  if (file) ingest(await file.text());
});
$('import-url').addEventListener('click', async () => {
  const url = prompt('Repository JSON URL (https):');
  if (!url) return;
  try { ingest(await (await fetch(url)).text()); }
  catch (error) { alert('Could not fetch that URL: ' + error.message); }
});
$('load-sample').addEventListener('click', () => ingest(JSON.stringify({
  name: 'Sample Repository', identifier: 'com.example.sample',
  iconURL: 'https://example.com/icon.png', sourceURL: 'https://example.com/source.json',
  apps: [{ name: 'Sample App', bundleIdentifier: 'com.example.sample.app', version: '1.0',
           versionDate: today(), developerName: 'Example', downloadURL: 'https://example.com/app.ipa',
           iconURL: 'https://example.com/app.png', size: 12345678, category: 'Utilities',
           localizedDescription: 'A sample entry to edit.', screenshotURLs: [] }]
})));

render();
</script>
"""
    return web_chrome.page("Repository Creator", body, request, subtitle="Build and export an AltStore-compatible feed.", scripts=scripts)
