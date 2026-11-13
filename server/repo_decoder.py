#!/usr/bin/env python3
"""Repository Decoder — read any source feed and see what it really says.

    GET  /tools/repo-decoder          the page
    POST /api/tools/repo/decode       fetch or paste a feed, normalise + lint it
    POST /api/tools/repo/convert      re-export the same feed in another dialect

Source feeds have at least four dialects in the wild: AltStore v1 (`source.json`
with `bundleIdentifier`), the SideStore variant that adds `versions[]`, the
Feather/ESign "flat" schema (`bundleID`, `appDescription`), and the legacy
AltServer `appdata` XML this repo's own server still emits. Same idea, four
spellings — which is why "my repo shows up empty" is a common complaint.

This tool parses all of them, maps every spelling onto one canonical shape, and
then lints the result with `repo_creator.validate_draft` — the same validator the
Repository Creator uses, so a feed that decodes cleanly here also exports
cleanly there.

Fetch policy: public feeds only — private, loopback, link-local, CGNAT, and
internal hostnames are blocked on both initial URLs and redirects, the response
is capped at 4 MiB, redirects are followed only as http(s), and nothing is stored.
"""

from __future__ import annotations

import json
import xml.etree.ElementTree as ET
from typing import Any
from urllib.parse import urljoin, urlparse

import httpx
from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel

import repo_creator
from repo_creator import RepoApp, RepoDraft, build_export, validate_draft
from url_guard import public_url_error, should_resolve_dns
from web_chrome import page

router = APIRouter()

MAX_FETCH_BYTES = 4 * 1024 * 1024
FETCH_TIMEOUT_SECONDS = 20.0
MAX_REDIRECTS = 5
REDIRECT_STATUSES = frozenset({301, 302, 303, 307, 308})

# Canonical key -> every spelling seen in the wild. First match wins, so order
# the most specific alias first.
APP_ALIASES: dict[str, tuple[str, ...]] = {
    "name": ("name", "appName", "appTitle", "title"),
    "bundleIdentifier": (
        "bundleIdentifier",
        "bundleID",
        "bundleId",
        "bundleIDentifier",
        "cfBundleIdentifier",
        "bundleid",
    ),
    "version": ("version", "versionNumber", "appVersion", "versionString"),
    "versionDate": ("versionDate", "releaseDate", "updatedAt", "date", "updated"),
    "localizedDescription": (
        "localizedDescription",
        "appDescription",
        "description",
        "descriptionText",
        "summary",
    ),
    "iconURL": ("iconURL", "iconUrl", "icon", "artworkUrl", "artworkURL", "iconurl"),
    "screenshotURLs": ("screenshotURLs", "screenshots", "screenshotURL", "screenshoturl"),
    "downloadURL": ("downloadURL", "downloadUrl", "download_url", "ipaURL", "ipaurl", "fileURL", "url"),
    "size": ("size", "fileSize", "bytes"),
    "developerName": ("developerName", "developer", "author", "team"),
    "category": ("category", "genre", "primaryGenreName"),
    "tintColor": ("tintColor", "tint", "color"),
    "subtitle": ("subtitle", "tagline", "shortDescription"),
}

SOURCE_ALIASES: dict[str, tuple[str, ...]] = {
    "name": ("name", "sourceName", "title"),
    "identifier": ("identifier", "bundleIdentifier", "sourceIdentifier", "id"),
    "subtitle": ("subtitle", "tagline"),
    "description": ("description", "localizedDescription"),
    "iconURL": ("iconURL", "iconUrl", "icon"),
    "sourceURL": ("sourceURL", "sourceUrl", "feedURL", "url"),
    "website": ("website", "homepage", "site"),
    "tintColor": ("tintColor", "tint"),
}

# XML tags used by the legacy AltServer appdata feed (and this repo's own
# `repo_store.appdata_xml`).
XML_APP_TAGS = {
    "name": ("title", "name", "appname"),
    "bundleIdentifier": ("bundleid", "bundleidentifier", "bundleIdentifier"),
    "version": ("version", "versionnumber"),
    "downloadURL": ("ipaurl", "downloadurl", "url"),
    "iconURL": ("iconurl", "icon"),
    "screenshotURLs": ("screenshoturl", "screenshots"),
    "localizedDescription": ("description", "appdescription"),
    "developerName": ("developer", "developername"),
    "size": ("size",),
}


# ---------------------------------------------------------------------------\
# Fetching and parsing
# ---------------------------------------------------------------------------

class DecodeBody(BaseModel):
    # Either a URL to fetch or the feed text pasted into the page. `payload`
    # wins when both are given, so the page can round-trip what it shows.
    source: str = ""
    payload: str = ""


class ConvertBody(DecodeBody):
    format: str = "altstore"


def _make_client() -> httpx.Client:
    """Factory so tests can substitute an httpx.MockTransport."""
    return httpx.Client(timeout=FETCH_TIMEOUT_SECONDS, follow_redirects=False)


def fetch_text(url: str) -> str:
    stripped = url.strip()
    if refusal := public_url_error(stripped, resolve_dns=False):
        raise HTTPException(status_code=422, detail=refusal)

    chunks: list[bytes] = []
    total = 0
    try:
        with _make_client() as client:
            resolve_dns = should_resolve_dns(client)
            current_url = stripped
            for hop in range(MAX_REDIRECTS + 1):
                if refusal := public_url_error(current_url, resolve_dns=resolve_dns):
                    raise HTTPException(status_code=422, detail=refusal)
                with client.stream(
                    "GET",
                    current_url,
                    headers={"User-Agent": "VexSign-RepoDecoder/1.0"},
                    follow_redirects=False,
                ) as response:
                    if response.status_code in REDIRECT_STATUSES and response.headers.get("location"):
                        if hop >= MAX_REDIRECTS:
                            raise HTTPException(status_code=422, detail="Too many redirects.")
                        current_url = urljoin(current_url, response.headers["location"].strip())
                        continue
                    if response.status_code != 200:
                        raise HTTPException(
                            status_code=502,
                            detail=f"{stripped} returned {response.status_code}.",
                        )
                    final = urlparse(str(response.url))
                    if final.scheme not in ("http", "https"):
                        raise HTTPException(status_code=422, detail="That URL redirected somewhere unexpected.")
                    for chunk in response.iter_bytes(65_536):
                        total += len(chunk)
                        if total > MAX_FETCH_BYTES:
                            raise HTTPException(
                                status_code=413,
                                detail=f"Feed is larger than {MAX_FETCH_BYTES // (1024 * 1024)} MiB; paste it instead.",
                            )
                        chunks.append(chunk)
                    break
    except httpx.HTTPError as error:
        raise HTTPException(status_code=502, detail=f"Could not fetch {stripped}: {error}")

    return b"".join(chunks).decode("utf-8", "replace")


def _as_list(value: Any) -> list[str]:
    if isinstance(value, list):
        return [str(item) for item in value if isinstance(item, (str, int, float)) and str(item).strip()]
    if isinstance(value, str) and value.strip():
        return [value.strip()]
    return []


def _pick(raw: dict[str, Any], aliases: tuple[str, ...], used: dict[str, int]) -> Any:
    for alias in aliases:
        if alias in raw and raw[alias] not in (None, "", []):
            if alias != aliases[0]:
                used[alias] = used.get(alias, 0) + 1
            return raw[alias]
    return None


def normalise_app(raw: dict[str, Any], used: dict[str, int]) -> dict[str, Any]:
    """Map one app object onto the canonical `RepoApp` shape."""
    out: dict[str, Any] = {}
    for canonical, aliases in APP_ALIASES.items():
        value = _pick(raw, aliases, used)
        if value is None:
            continue
        if canonical == "screenshotURLs":
            out[canonical] = _as_list(value)
        elif canonical == "size":
            try:
                out[canonical] = int(float(value))
            except (TypeError, ValueError):
                out[canonical] = 0
        else:
            out[canonical] = str(value).strip()
    return out


def _apps_from_xml(text: str) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    root = ET.fromstring(text)
    apps: list[dict[str, Any]] = []
    for element in root.iter():
        if element.tag.lower() not in ("app", "record", "item"):
            continue
        fields = {child.tag.lower(): (child.text or "").strip() for child in element}
        app: dict[str, Any] = {}
        for canonical, tags in XML_APP_TAGS.items():
            for tag in tags:
                if fields.get(tag):
                    if canonical == "screenshotURLs":
                        app[canonical] = [fields[tag]]
                    elif canonical == "size":
                        try:
                            app[canonical] = int(float(fields[tag]))
                        except ValueError:
                            continue
                    else:
                        app[canonical] = fields[tag]
                    break
        if app:
            apps.append(app)
    source = {"name": (root.attrib.get("name") or "").strip(), "apps": len(apps)}
    return source, apps


def detect_format(payload: Any, was_xml: bool) -> str:
    if was_xml:
        return "appdata-xml"
    if isinstance(payload, list):
        return "apps.json"
    if not isinstance(payload, dict):
        return "unknown"
    apps = payload.get("apps")
    if not isinstance(apps, list):
        return "unknown"
    if not apps:
        # Well-formed but empty: dialects are only tellable apart by an app's
        # keys, so a feed with `name`/`identifier` and no apps is reported as
        # AltStore and the validator flags the empty list separately.
        return "altstore" if ("identifier" in payload or "name" in payload) else "unknown"
    first = apps[0] if isinstance(apps[0], dict) else {}
    if isinstance(first.get("versions"), list):
        return "altstore+versions"
    if "bundleID" in first or "appDescription" in first:
        return "flat"
    return "altstore"


def decode_payload(text: str) -> dict[str, Any]:
    body = text.strip()
    if not body:
        raise HTTPException(status_code=422, detail="Nothing to decode — paste a feed or give a URL.")

    was_xml = body.startswith("<")
    apps: list[dict[str, Any]] = []
    source: dict[str, Any] = {}
    extra: dict[str, Any] = {}

    if was_xml:
        try:
            source, apps = _apps_from_xml(body)
        except ET.ParseError as error:
            raise HTTPException(status_code=422, detail=f"That is not valid XML: {error}")
        payload: Any = None
    else:
        try:
            payload = json.loads(body)
        except json.JSONDecodeError as error:
            raise HTTPException(
                status_code=422,
                detail=f"That is not valid JSON: {error.msg} at line {error.lineno} column {error.colno}.",
            )

        if isinstance(payload, list):
            apps = [item for item in payload if isinstance(item, dict)]
        elif isinstance(payload, dict):
            raw_apps = payload.get("apps")
            if isinstance(raw_apps, list):
                apps = [item for item in raw_apps if isinstance(item, dict)]
            for canonical, aliases in SOURCE_ALIASES.items():
                value = payload.get(aliases[0])
                if value in (None, ""):
                    value = _pick(payload, aliases, {})
                if isinstance(value, str) and value.strip():
                    source[canonical] = value.strip()
            for key in ("news", "userInfo", "patreon"):
                if isinstance(payload.get(key), list) and payload[key]:
                    extra[f"{key}Entries"] = len(payload[key])

    used: dict[str, int] = {}
    normalised = [normalise_app(app, used) for app in apps]
    fmt = detect_format(payload, was_xml)

    draft = RepoDraft(
        name=source.get("name") or "Decoded Repository",
        identifier=source.get("identifier") or "",
        subtitle=source.get("subtitle") or "",
        description=source.get("description") or "",
        iconURL=source.get("iconURL") or "",
        sourceURL=source.get("sourceURL") or "",
        website=source.get("website") or "",
        tintColor=source.get("tintColor") or "",
        apps=[RepoApp(**app) for app in normalised],
    )
    issues = validate_draft(draft)

    versions = sum(len(app.get("versions") or []) for app in apps if isinstance(app, dict))
    return {
        "format": fmt,
        "source": source,
        "apps": normalised,
        "issues": [issue.model_dump() for issue in issues],
        "errorCount": sum(1 for issue in issues if issue.severity == "error"),
        "warningCount": sum(1 for issue in issues if issue.severity == "warning"),
        "aliasesUsed": dict(sorted(used.items(), key=lambda item: -item[1])),
        "stats": {
            "apps": len(normalised),
            "withDownloadURL": sum(1 for app in normalised if app.get("downloadURL")),
            "withIcon": sum(1 for app in normalised if app.get("iconURL")),
            "withScreenshots": sum(1 for app in normalised if app.get("screenshotURLs")),
            "totalBytes": sum(int(app.get("size") or 0) for app in normalised),
            "inlineVersionEntries": versions,
        },
        "extra": extra,
    }


def _draft_from(text: str) -> tuple[RepoDraft, dict[str, Any]]:
    decoded = decode_payload(text)
    draft = RepoDraft(
        name=decoded["source"].get("name") or "Decoded Repository",
        identifier=decoded["source"].get("identifier") or "",
        subtitle=decoded["source"].get("subtitle") or "",
        description=decoded["source"].get("description") or "",
        iconURL=decoded["source"].get("iconURL") or "",
        sourceURL=decoded["source"].get("sourceURL") or "",
        website=decoded["source"].get("website") or "",
        tintColor=decoded["source"].get("tintColor") or "",
        apps=[RepoApp(**app) for app in decoded["apps"]],
    )
    return draft, decoded


def _resolve(body: DecodeBody) -> str:
    if body.payload.strip():
        return body.payload
    if body.source.strip():
        return fetch_text(body.source)
    raise HTTPException(status_code=422, detail="Give a feed URL or paste the feed contents.")


# ---------------------------------------------------------------------------\
# Routes
# ---------------------------------------------------------------------------

@router.post("/api/tools/repo/decode")
def api_decode(body: DecodeBody) -> dict[str, Any]:
    return decode_payload(_resolve(body))


@router.post("/api/tools/repo/convert")
def api_convert(body: ConvertBody) -> dict[str, Any]:
    if body.format not in ("altstore", "flat", "apps"):
        raise HTTPException(
            status_code=422,
            detail="format must be one of altstore, flat, apps.",
        )
    draft, decoded = _draft_from(_resolve(body))
    exported = build_export(draft, body.format)
    return {
        "filename": exported["filename"],
        "fromFormat": decoded["format"],
        "format": body.format,
        "json": json.dumps(exported["payload"], indent=2, ensure_ascii=False),
        "errorCount": decoded["errorCount"],
        "appCount": len(draft.apps),
    }


# ---------------------------------------------------------------------------\
# Page
# ---------------------------------------------------------------------------

PAGE_SCRIPT = """
<script>
const $ = (id) => document.getElementById(id);

function pill(text, kind) {
  return '<span class="pill ' + kind + '">' + esc(text) + '</span>';
}

function renderIssues(issues) {
  if (!issues.length) return '<div class="issue note">No problems found.</div>';
  return issues.map((issue) =>
    '<div class="issue ' + esc(issue.severity) + '">' +
    (issue.app ? '<strong>' + esc(issue.app) + '</strong> — ' : '') + esc(issue.message) +
    (issue.suggestion ? ' <span class="muted">' + esc(issue.suggestion) + '</span>' : '') +
    '</div>').join('');
}

function renderApps(apps) {
  if (!apps.length) return '<p class="muted">No apps in this feed.</p>';
  const rows = apps.map((app) =>
    '<tr><td>' + (app.name ? esc(app.name) : '<em class="muted">unnamed</em>') + '</td>' +
    '<td><code>' + esc(app.bundleIdentifier || '—') + '</code></td>' +
    '<td>' + esc(app.version || '—') + '</td>' +
    '<td>' + esc(app.developerName || '—') + '</td>' +
    '<td>' + (app.size ? (app.size / 1048576).toFixed(1) + ' MB' : '—') + '</td>' +
    '<td>' + (app.downloadURL ? pill('download', 'ok') : pill('missing', 'bad')) + '</td>' +
    '<td>' + (app.iconURL ? pill('icon', 'ok') : pill('none', 'idle')) + '</td></tr>').join('');
  return '<table><thead><tr><th>Name</th><th>Bundle ID</th><th>Version</th><th>Developer</th>' +
    '<th>Size</th><th>Download</th><th>Icon</th></tr></thead><tbody>' + rows + '</tbody></table>';
}

async function decode() {
  const result = $('result');
  result.innerHTML = '<p class="muted">Decoding…</p>';
  try {
    const response = await fetch('/api/tools/repo/decode', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ source: $('url').value.trim(), payload: $('payload').value })
    });
    const body = await response.json();
    if (!response.ok) throw new Error(body.detail || response.statusText);

    const kind = body.errorCount ? 'bad' : (body.warningCount ? 'warn' : 'ok');
    const aliases = Object.entries(body.aliasesUsed)
      .map(([key, count]) => '<code>' + esc(key) + '</code> ×' + esc(count)).join(' ');
    const stats = body.stats;

    result.innerHTML =
      '<div class="row">' + pill(body.format, 'idle') +
      '<span class="muted">' + stats.apps + ' apps · ' + stats.withDownloadURL + ' with download URLs · ' +
      (stats.totalBytes / 1048576).toFixed(1) + ' MB total · ' +
      stats.inlineVersionEntries + ' inline version entries</span></div>' +
      (aliases ? '<p class="muted" style="margin-top:0.5rem">Normalised from: ' + aliases + '</p>' : '') +
      '<h2 style="margin-top:1rem">Apps</h2>' + renderApps(body.apps) +
      '<h2 style="margin-top:1rem">Issues (' + body.errorCount + ' errors, ' + body.warningCount + ' warnings)</h2>' +
      renderIssues(body.issues) +
      '<div class="row" style="margin-top:1rem">' +
      '<button class="btn secondary" data-format="altstore">Export AltStore / SideStore</button>' +
      '<button class="btn secondary" data-format="flat">Export flat schema</button>' +
      '<button class="btn secondary" data-format="apps">Export apps.json</button>' +
      '<button class="btn ghost" id="copy-json">Copy normalised JSON</button></div>' +
      '<pre id="json" hidden></pre>';

    window.__decoded = body;
    result.querySelectorAll('[data-format]').forEach((button) =>
      button.addEventListener('click', () => convert(button.dataset.format)));
    $('copy-json').addEventListener('click', () => {
      const pre = $('json');
      pre.hidden = !pre.hidden;
      if (!pre.hidden) {
        pre.textContent = JSON.stringify({ source: body.source, apps: body.apps }, null, 2);
      }
    });
  } catch (error) {
    result.innerHTML = '<div class="issue error">' + esc(error.message) + '</div>';
  }
}

async function convert(format) {
  const response = await fetch('/api/tools/repo/convert', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      source: $('url').value.trim(),
      payload: $('payload').value,
      format
    })
  });
  const body = await response.json();
  if (!response.ok) {
    alert(body.detail || response.statusText);
    return;
  }
  const blob = new Blob([body.json], { type: 'application/json' });
  const link = document.createElement('a');
  link.href = URL.createObjectURL(blob);
  link.download = body.filename;
  document.body.appendChild(link);
  link.click();
  link.remove();
}

const SAMPLE = {
  name: 'Sample Repository',
  identifier: 'com.example.store',
  apps: [
    {
      name: 'Sample App',
      bundleID: 'com.example.app',
      version: '1.2',
      versionDate: '2026-09-01T12:00:00Z',
      downloadURL: 'https://example.com/app.ipa',
      iconURL: 'https://example.com/icon.png',
      developerName: 'Example',
      size: 12345678,
      appDescription: 'A sample entry with flat-schema keys.'
    }
  ]
};

document.addEventListener('DOMContentLoaded', () => {
  $('decode').addEventListener('click', decode);
  $('load-sample').addEventListener('click', () => {
    $('payload').value = JSON.stringify(SAMPLE, null, 2);
    $('url').value = '';
    decode();
  });
  $('picker').addEventListener('change', (event) => {
    const file = event.target.files[0];
    if (!file) return;
    const reader = new FileReader();
    reader.onload = () => { $('payload').value = String(reader.result); decode(); };
    reader.readAsText(file);
  });
  $('browse').addEventListener('click', () => $('picker').click());
});
</script>
"""


@router.get("/tools/repo-decoder")
def repo_decoder_page(request: Request):
    body = """
  <div class="card">
    <h2>Feed</h2>
    <div class="grid two">
      <div>
        <label>Feed URL</label>
        <input id="url" placeholder="https://apps.altstore.io/source.json" autocomplete="off">
      </div>
      <div style="display:flex;align-items:flex-end;gap:0.5rem">
        <button class="btn" id="decode">Decode</button>
        <button class="btn ghost" id="load-sample">Sample</button>
        <button class="btn ghost" id="browse">Open file…</button>
        <input type="file" id="picker" accept=".json,.xml,application/json,text/xml" hidden>
      </div>
    </div>
    <label style="margin-top:0.7rem">…or paste the feed</label>
    <textarea id="payload" placeholder='{"name": "…", "apps": [ … ]}'></textarea>
    <p class="muted">AltStore v1, SideStore (<code>versions[]</code>), the Feather/ESign flat schema,
      bare <code>apps.json</code> and legacy <code>appdata</code> XML are all understood.</p>
  </div>

  <div class="card">
    <h2>Result</h2>
    <div id="result"><p class="muted">Nothing decoded yet.</p></div>
  </div>
"""
    return page(
        "Repository Decoder",
        body,
        request,
        subtitle="Read any source feed, see what it really contains, export it in another dialect.",
        scripts=PAGE_SCRIPT,
    )
