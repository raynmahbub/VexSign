#!/usr/bin/env python3
"""Shared page chrome for the browser tools in `web_tools.py`.

Kept in its own module because every tool renders through `page()`, and the tool
modules are imported *by* `web_tools` — putting the helper there would be a
circular import.
"""

from __future__ import annotations

import html

from fastapi import Request
from fastapi.responses import HTMLResponse

# ---------------------------------------------------------------------------
# Shared page chrome
# ---------------------------------------------------------------------------

PAGE_CSS = """
  :root { color-scheme: light dark; --accent: #c96fad; }
  * { box-sizing: border-box; }
  body { font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
         margin: 0; background: #0f0f14; color: #f2f2f5; line-height: 1.45; }
  @media (prefers-color-scheme: light) {
    body { background: #fafafa; color: #1c1c1e; }
    .card { background: #fff !important; border-color: #e5e5ea !important; }
    code, pre, input, select, textarea { background: #f2f2f7 !important; border-color: #d8d8de !important; color: #1c1c1e !important; }
    th { background: #f2f2f7 !important; }
    .muted { color: #6b6b72 !important; }
    .btn.secondary { background: #ececf1 !important; }
  }
  header { padding: 1rem 1.25rem; border-bottom: 1px solid #2c2c34; display: flex;
           align-items: center; gap: 0.75rem; }
  header a.brand { font-weight: 700; text-decoration: none; color: inherit; font-size: 1.05rem; }
  header nav { margin-left: auto; display: flex; gap: 0.9rem; font-size: 0.9rem; }
  header nav a { color: var(--accent); text-decoration: none; }
  main { max-width: 1080px; margin: 0 auto; padding: 1.25rem; }
  h1 { font-size: 1.5rem; margin: 0.5rem 0 0.25rem; }
  h2 { font-size: 1.05rem; margin: 0 0 0.75rem; }
  .card { background: #17171d; border: 1px solid #2c2c34; border-radius: 14px;
          padding: 1rem 1.1rem; margin: 0.9rem 0; }
  .grid { display: grid; gap: 0.75rem; }
  @media (min-width: 820px) { .grid.two { grid-template-columns: 1fr 1fr; } }
  label { display: block; font-size: 0.8rem; color: #98989f; margin-bottom: 0.2rem; }
  input, select, textarea { width: 100%; background: #101016; color: inherit;
    border: 1px solid #2c2c34; border-radius: 9px; padding: 0.5rem 0.6rem;
    font: inherit; font-size: 0.9rem; }
  textarea { min-height: 84px; resize: vertical; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 0.8rem; }
  input:focus, select:focus, textarea:focus { outline: 2px solid var(--accent); outline-offset: -1px; }
  .btn { appearance: none; border: 0; border-radius: 9px; padding: 0.5rem 0.85rem;
         font: inherit; font-size: 0.88rem; font-weight: 600; cursor: pointer;
         background: var(--accent); color: #1a0f16; text-decoration: none; display: inline-block; }
  .btn.secondary { background: #26262e; color: inherit; }
  .btn.ghost { background: transparent; color: var(--accent); border: 1px solid #3a3a44; }
  .btn[disabled] { opacity: 0.5; cursor: default; }
  .row { display: flex; flex-wrap: wrap; gap: 0.5rem; align-items: center; }
  code { background: #26262e; padding: 0.12rem 0.35rem; border-radius: 5px;
         font-size: 0.82em; word-break: break-all; }
  pre { background: #101016; border: 1px solid #2c2c34; border-radius: 10px;
        padding: 0.75rem; overflow: auto; font-size: 0.78rem; max-height: 340px; }
  table { width: 100%; border-collapse: collapse; font-size: 0.85rem; }
  th, td { text-align: left; padding: 0.4rem 0.5rem; border-bottom: 1px solid #2c2c34; vertical-align: top; }
  th { color: #98989f; font-weight: 600; font-size: 0.78rem; text-transform: uppercase; letter-spacing: 0.03em; }
  .muted { color: #98989f; font-size: 0.85em; }
  .pill { display: inline-block; padding: 0.1rem 0.5rem; border-radius: 999px;
          font-size: 0.72rem; font-weight: 700; letter-spacing: 0.02em; }
  .pill.ok { background: #12351f; color: #4ade80; }
  .pill.warn { background: #3a2c08; color: #fbbf24; }
  .pill.bad { background: #3d1414; color: #f87171; }
  .pill.idle { background: #26262e; color: #98989f; }
  .issue { padding: 0.35rem 0.5rem; border-radius: 8px; margin: 0.25rem 0; font-size: 0.83rem; }
  .issue.error { background: #3d141433; border-left: 3px solid #f87171; }
  .issue.warning { background: #3a2c0833; border-left: 3px solid #fbbf24; }
  .issue.note { background: #26262e66; border-left: 3px solid #6b6b72; }
  .drop { border: 2px dashed #3a3a44; border-radius: 14px; padding: 1.5rem; text-align: center; }
  .drop.hot { border-color: var(--accent); background: #c96fad12; }
  .stack { display: grid; gap: 0.6rem; }
  footer { text-align: center; color: #98989f; font-size: 0.8rem; padding: 1.5rem; }
  footer a { color: var(--accent); }
"""

TOOLS = [
    (
        "/tools/signer",
        "Signer Console",
        "Drive the phone's on-device signer from a browser: queue IPAs, get signed ones back.",
        "hammer",
    ),
    (
        "/tools/repo-creator",
        "Repository Creator",
        "Build, validate and export an AltStore-compatible source feed in the browser.",
        "shippingbox",
    ),
    (
        "/tools/repo-decoder",
        "Repository Decoder",
        "Read any source feed, normalise its dialects and export it in another schema.",
        "doc.text.viewfinder",
    ),
    (
        "/tools/app-installer",
        "App Installer",
        "Build an OTA install link from a hosted IPA, and check the URL will really install.",
        "square.and.arrow.down.on.square",
    ),
    (
        "/tools/cert-check",
        "Certificate Status Checker",
        "Read expiry, team, entitlements and device scope from a provisioning profile.",
        "checkmark.shield",
    ),
    (
        "/tools/udid",
        "UDID Grabber",
        "Install a one-time enrolment profile on an iPhone and read its UDID here.",
        "iphone",
    ),
]


def page(title: str, body: str, request: Request, subtitle: str = "", scripts: str = "") -> HTMLResponse:
    """Wrap a page body in the shared chrome.

    `subtitle` and `body` are supplied by this module (never by request data);
    anything interpolated from the request is escaped by the caller.
    """
    nav = " ".join(
        f'<a href="{href}">{html.escape(name)}</a>' for href, name, _, _ in TOOLS
    )
    sub = f'<p class="muted">{subtitle}</p>' if subtitle else ""
    return HTMLResponse(
        f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{html.escape(title)} · VexSign</title>
<style>{PAGE_CSS}</style>
</head>
<body>
<header>
  <a class="brand" href="/tools">VexSign Tools</a>
  <nav>{nav}</nav>
</header>
<main>
  <h1>{html.escape(title)}</h1>
  {sub}
  {body}
</main>
<footer>
  VexSign is open source: <a href="https://github.com/raynmahbub/VexSign">github.com/raynmahbub/VexSign</a>.
  These tools run on your own deployment and keep no logs of what you upload.
</footer>
{scripts}
</body>
</html>
"""
    )


