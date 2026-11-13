#!/usr/bin/env python3
"""App Installer — turn a hosted IPA into a working `itms-services://` link.

    GET  /tools/app-installer          the page
    POST /api/tools/install/manifest   build the manifest plist + install link
    POST /api/tools/install/probe      check that the IPA URL is actually installable

The Repository Creator already emits an OTA manifest for apps it knows about.
This tool is the standalone version of that step: you have an IPA on an HTTPS
host (a release, a CI artefact, your own bucket) and you want the link iOS will
accept, without hand-writing a plist.

It also probes the URL, because the two failure modes that waste an afternoon are
invisible from the plist alone:

* the server answers `HEAD` with 405, or 404s only for the exact path;
* the URL redirects to a host that is not HTTPS — `itms-services` refuses
  cleartext anywhere in the chain, and the error on-device is just a spinner.

Nothing is uploaded or hosted here. You get a `manifest.plist` to put on your own
HTTPS host and a link to open on the device.
"""

from __future__ import annotations

import plistlib
from typing import Any
from urllib.parse import urljoin, urlparse

import httpx
from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel

from repo_creator import RepoApp, build_manifest, install_link
from url_guard import public_url_error, should_resolve_dns
from web_chrome import page

router = APIRouter()

PROBE_TIMEOUT_SECONDS = 20.0
# Only headers are wanted; a ranged GET is used when HEAD is refused.
PROBE_RANGE_BYTES = 4096
MAX_REDIRECTS = 5
REDIRECT_STATUSES = frozenset({301, 302, 303, 307, 308})

INSTALLABLE_CONTENT_TYPES = (
    "application/octet-stream",
    "application/zip",
    "application/x-zip",
    "application/x-zip-compressed",
)


class ManifestBody(BaseModel):
    ipaURL: str
    manifestURL: str = ""
    name: str = ""
    bundleIdentifier: str = ""
    version: str = ""
    size: int = 0
    subtitle: str = ""
    displayImageURL: str = ""
    fullSizeImageURL: str = ""
    # Probe the IPA URL before building, and use its Content-Length as the size
    # when the caller does not know it. Off by default so the endpoint stays
    # usable without outbound network access.
    probe: bool = False


class ProbeBody(BaseModel):
    ipaURL: str


def _make_client() -> httpx.Client:
    """Factory so tests can substitute an httpx.MockTransport."""
    return httpx.Client(timeout=PROBE_TIMEOUT_SECONDS, follow_redirects=False)


class UnsafeTargetError(ValueError):
    """Raised when an initial or redirected URL resolves to a blocked target."""


def _request_with_safe_redirects(
    client: httpx.Client,
    method: str,
    url: str,
    *,
    headers: dict[str, str] | None = None,
) -> tuple[httpx.Response, list[str]]:
    """Follow redirects one hop at a time, blocking non-public targets before sending."""
    resolve_dns = should_resolve_dns(client)
    current_url = url
    current_method = method
    redirects: list[str] = []

    for _ in range(MAX_REDIRECTS + 1):
        refusal = public_url_error(current_url, resolve_dns=resolve_dns)
        if refusal:
            raise UnsafeTargetError(refusal)
        response = client.request(
            current_method,
            current_url,
            headers=headers,
            follow_redirects=False,
        )
        if response.status_code in REDIRECT_STATUSES and response.headers.get("location"):
            if len(redirects) >= MAX_REDIRECTS:
                raise ValueError(f"Too many redirects (more than {MAX_REDIRECTS}).")
            redirects.append(current_url)
            next_url = urljoin(current_url, response.headers["location"].strip())
            if response.status_code == 303:
                current_method = "GET"
            current_url = next_url
            continue
        return response, redirects

    raise ValueError(f"Too many redirects (more than {MAX_REDIRECTS}).")


def _issue(severity: str, message: str, suggestion: str = "") -> dict[str, str]:
    return {"severity": severity, "message": message, "suggestion": suggestion}


def _require_https(url: str, what: str) -> list[dict[str, str]]:
    issues: list[dict[str, str]] = []
    parsed = urlparse(url)
    if parsed.scheme != "https":
        issues.append(
            _issue(
                "error",
                f"The {what} must be https ({parsed.scheme or 'no scheme'} given).",
                "iOS refuses cleartext OTA installs, and ATS blocks http fetches.",
            )
        )
    return issues


def probe_url(url: str) -> dict[str, Any]:
    """Answer `HEAD`, falling back to a ranged GET, and report what iOS would see."""
    result: dict[str, Any] = {
        "url": url,
        "https": url.startswith("https://"),
        "method": "HEAD",
        "status": 0,
        "contentType": "",
        "contentLength": 0,
        "effectiveURL": "",
        "redirects": [],
        "ok": False,
        "issues": [],
    }

    try:
        with _make_client() as client:
            if refusal := public_url_error(url, resolve_dns=should_resolve_dns(client)):
                result["issues"].append(_issue("error", refusal))
                return result

            response, redirects = _request_with_safe_redirects(client, "HEAD", url)
            if response.status_code in (403, 405, 501):
                # Plenty of static hosts reject HEAD; a ranged GET says the same thing.
                result["method"] = "GET"
                response, redirects = _request_with_safe_redirects(
                    client,
                    "GET",
                    url,
                    headers={"Range": f"bytes=0-{PROBE_RANGE_BYTES - 1}"},
                )
            result["status"] = response.status_code
            result["contentType"] = response.headers.get("content-type", "").split(";")[0].strip()
            result["effectiveURL"] = str(response.url)
            result["redirects"] = redirects
            length = response.headers.get("content-length")
            if length and length.isdigit():
                result["contentLength"] = int(length)
    except UnsafeTargetError:
        raise
    except ValueError as error:
        result["issues"].append(_issue("error", str(error)))
        return result
    except httpx.HTTPError as error:
        result["issues"].append(_issue("error", f"Could not reach the IPA: {error}"))
        return result

    if result["status"] == 0:
        result["issues"].append(_issue("error", "The IPA URL did not answer."))
        return result

    if result["status"] not in (200, 206):
        result["issues"].append(
            _issue(
                "error",
                f"{result['url']} returned {result['status']}.",
                "The device will only see a spinner; fix the URL or its permissions first.",
            )
        )

    if result["effectiveURL"] and not result["effectiveURL"].startswith("https://"):
        result["issues"].append(
            _issue(
                "error",
                "The URL redirects to a non-https address.",
                f"Final address: {result['effectiveURL']}",
            )
        )

    if result["contentType"] and result["contentType"] not in INSTALLABLE_CONTENT_TYPES:
        result["issues"].append(
            _issue(
                "warning",
                f"Content-Type is {result['contentType']}, not a binary download.",
                "An HTML error page here installs nothing. application/octet-stream is expected.",
            )
        )

    if not result["contentLength"]:
        result["issues"].append(
            _issue("warning", "The server sent no Content-Length.", "iOS can install, but progress is unknown.")
        )

    result["ok"] = not any(issue["severity"] == "error" for issue in result["issues"])
    return result


@router.post("/api/tools/install/probe")
def api_probe(body: ProbeBody) -> dict[str, Any]:
    url = body.ipaURL.strip()
    if not url:
        raise HTTPException(status_code=422, detail="Give the IPA URL to check.")
    if refusal := public_url_error(url, resolve_dns=False):
        raise HTTPException(status_code=422, detail=refusal)
    try:
        return probe_url(url)
    except UnsafeTargetError as error:
        raise HTTPException(status_code=422, detail=str(error))


@router.post("/api/tools/install/manifest")
def api_manifest(body: ManifestBody) -> dict[str, Any]:
    ipa = body.ipaURL.strip()
    manifest_url = body.manifestURL.strip()
    if not ipa:
        raise HTTPException(status_code=422, detail="Give the https URL of the IPA.")
    if body.probe:
        if refusal := public_url_error(ipa, resolve_dns=False):
            raise HTTPException(status_code=422, detail=refusal)

    issues = _require_https(ipa, "IPA URL") + _require_https(manifest_url, "manifest URL")
    if any(issue["severity"] == "error" for issue in issues):
        raise HTTPException(status_code=422, detail="; ".join(issue["message"] for issue in issues))

    probe: dict[str, Any] | None = None
    size = body.size
    if body.probe:
        try:
            probe = probe_url(ipa)
        except UnsafeTargetError as error:
            raise HTTPException(status_code=422, detail=str(error))
        issues.extend(probe["issues"])
        if not size and probe.get("contentLength"):
            size = probe["contentLength"]

    if not body.bundleIdentifier.strip():
        issues.append(
            _issue(
                "warning",
                "No bundle identifier given.",
                "iOS matches the installed app by bundle ID; without it this installs as a fresh app.",
            )
        )
    if not body.version.strip():
        issues.append(_issue("warning", "No version given; the manifest will say 1.0."))
    if not size:
        issues.append(_issue("note", "No file size recorded."))

    app = RepoApp(
        name=body.name,
        bundleIdentifier=body.bundleIdentifier,
        version=body.version or "1.0",
        subtitle=body.subtitle,
        downloadURL=ipa,
        size=size,
    )
    manifest = build_manifest(app, manifest_url, body.displayImageURL, body.fullSizeImageURL)

    # Sanity-check our own output: a malformed plist here would only surface on
    # the device, as a spinner that never resolves.
    parsed = plistlib.loads(manifest)
    if not parsed.get("items"):
        raise HTTPException(status_code=500, detail="Generated manifest has no items.")

    return {
        "manifest": manifest.decode("utf-8"),
        "manifestURL": manifest_url,
        "installLink": install_link(manifest_url),
        "ipaURL": ipa,
        "size": size,
        "probe": probe,
        "issues": issues,
        "errorCount": sum(1 for issue in issues if issue["severity"] == "error"),
        "warningCount": sum(1 for issue in issues if issue["severity"] == "warning"),
    }


PAGE_SCRIPT = """
<script>
const $ = (id) => document.getElementById(id);

function issueRow(issue) {
  return '<div class="issue ' + esc(issue.severity) + '">' + esc(issue.message) +
    (issue.suggestion ? ' <span class="muted">' + esc(issue.suggestion) + '</span>' : '') + '</div>';
}

async function post(path, payload) {
  const response = await fetch(path, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload)
  });
  const body = await response.json();
  if (!response.ok) throw new Error(body.detail || response.statusText);
  return body;
}

function fields() {
  return {
    ipaURL: $('ipa').value.trim(),
    manifestURL: $('manifest').value.trim(),
    name: $('name').value.trim(),
    bundleIdentifier: $('bundle').value.trim(),
    version: $('version').value.trim(),
    subtitle: $('subtitle').value.trim(),
    size: parseInt($('size').value, 10) || 0,
    displayImageURL: $('display').value.trim(),
    fullSizeImageURL: $('full').value.trim()
  };
}

async function build() {
  const result = $('result');
  result.innerHTML = '<p class="muted">Building…</p>';
  try {
    const body = await post('/api/tools/install/manifest',
      Object.assign(fields(), { probe: $('probe').checked }));
    window.__manifest = body;

    const probe = body.probe
      ? '<p class="muted">Probe: <code>' + esc(body.probe.method) + '</code> ' + esc(body.probe.status) +
        ' · ' + esc(body.probe.contentType || 'no content-type') +
        ' · ' + (body.probe.contentLength / 1048576).toFixed(1) + ' MB' +
        (body.probe.redirects.length ? ' · ' + body.probe.redirects.length + ' redirect(s)' : '') + '</p>'
      : '';

    result.innerHTML =
      '<div class="row"><span class="pill ' + (body.errorCount ? 'bad' : (body.warningCount ? 'warn' : 'ok')) + '">' +
      (body.errorCount ? body.errorCount + ' error(s)' : (body.warningCount ? body.warningCount + ' warning(s)' : 'looks installable')) +
      '</span></div>' + probe +
      '<div style="margin-top:0.6rem">' + body.issues.map(issueRow).join('') + '</div>' +
      '<h2 style="margin-top:1rem">Install link</h2>' +
      '<div class="row"><code id="link">' + esc(body.installLink) + '</code>' +
      '<button class="btn secondary" id="copy">Copy</button></div>' +
      '<p class="muted">Open that link on the device after the manifest is hosted at the URL above.</p>' +
      '<div class="row" style="margin-top:0.6rem">' +
      '<button class="btn" id="download">Download manifest.plist</button>' +
      '<button class="btn ghost" id="toggle">Show manifest XML</button></div>' +
      '<pre id="xml" hidden></pre>';

    $('copy').addEventListener('click', () => {
      navigator.clipboard.writeText(body.installLink).then(() => { $('copy').textContent = 'Copied'; });
    });
    $('download').addEventListener('click', () => {
      const link = document.createElement('a');
      link.href = URL.createObjectURL(new Blob([body.manifest], { type: 'application/xml' }));
      link.download = 'manifest.plist';
      document.body.appendChild(link);
      link.click();
      link.remove();
    });
    $('toggle').addEventListener('click', () => {
      const pre = $('xml');
      pre.hidden = !pre.hidden;
      pre.textContent = body.manifest;
    });
  } catch (error) {
    result.innerHTML = '<div class="issue error">' + esc(error.message) + '</div>';
  }
}

async function probeOnly() {
  const result = $('result');
  result.innerHTML = '<p class="muted">Probing…</p>';
  try {
    const body = await post('/api/tools/install/probe', { ipaURL: $('ipa').value.trim() });
    if (body.contentLength && !$('size').value) {
      $('size').value = String(body.contentLength);
    }
    result.innerHTML =
      '<div class="row"><span class="pill ' + (body.ok ? 'ok' : 'bad') + '">' +
      (body.ok ? 'reachable' : 'not installable') + '</span>' +
      '<span class="muted"><code>' + esc(body.method) + '</code> ' + esc(body.status) + ' · ' +
      esc(body.contentType || 'no content-type') + ' · ' +
      (body.contentLength ? (body.contentLength / 1048576).toFixed(1) + ' MB' : 'unknown size') + '</span></div>' +
      (body.redirects.length
        ? '<p class="muted">Redirects: ' + body.redirects.map((url) => '<code>' + esc(url) + '</code>').join(' → ') + '</p>'
        : '') +
      '<div style="margin-top:0.6rem">' + body.issues.map(issueRow).join('') + '</div>';
  } catch (error) {
    result.innerHTML = '<div class="issue error">' + esc(error.message) + '</div>';
  }
}

document.addEventListener('DOMContentLoaded', () => {
  $('build').addEventListener('click', build);
  $('probe-only').addEventListener('click', probeOnly);
  $('fill-manifest').addEventListener('click', () => {
    $('manifest').value = window.location.origin + '/manifest.plist';
  });
});
</script>
"""


@router.get("/tools/app-installer")
def app_installer_page(request: Request):
    body = """
  <div class="card">
    <h2>App</h2>
    <div class="grid two">
      <div>
        <label>IPA URL (must be https)</label>
        <input id="ipa" placeholder="https://files.example.com/App.ipa" autocomplete="off">
      </div>
      <div>
        <label>Where you will host manifest.plist (must be https)</label>
        <div class="row">
          <input id="manifest" placeholder="https://files.example.com/manifest.plist" autocomplete="off">
          <button class="btn ghost" id="fill-manifest">This host</button>
        </div>
      </div>
      <div><label>Name</label><input id="name" placeholder="My App"></div>
      <div><label>Bundle identifier</label><input id="bundle" placeholder="com.example.app"></div>
      <div><label>Version</label><input id="version" placeholder="1.0"></div>
      <div><label>Size in bytes (blank = ask the server)</label><input id="size" inputmode="numeric"></div>
      <div><label>Subtitle (optional)</label><input id="subtitle"></div>
      <div><label>Display image 57×57 (optional)</label><input id="display" placeholder="https://…/icon.png"></div>
      <div><label>Full-size image 512×512 (optional)</label><input id="full" placeholder="https://…/artwork.png"></div>
      <div style="display:flex;align-items:flex-end">
        <label class="row" style="font-size:0.85rem;color:inherit">
          <input type="checkbox" id="probe" checked style="width:auto"> Probe the IPA URL first
        </label>
      </div>
    </div>
    <div class="row" style="margin-top:0.7rem">
      <button class="btn" id="build">Build install link</button>
      <button class="btn secondary" id="probe-only">Probe only</button>
    </div>
    <p class="muted">Nothing is uploaded or hosted here: you get a <code>manifest.plist</code> for your own
      HTTPS host and the <code>itms-services://</code> link that points at it.</p>
  </div>

  <div class="card">
    <h2>Result</h2>
    <div id="result"><p class="muted">Nothing built yet.</p></div>
  </div>
"""
    return page(
        "App Installer",
        body,
        request,
        subtitle="Turn a hosted IPA into an OTA install link, and check that it will actually install.",
        scripts=PAGE_SCRIPT,
    )
