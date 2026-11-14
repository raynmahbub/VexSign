"""Regression tests: untrusted values must be escaped before reaching innerHTML.

Several web tools render data that originates outside this server:

  * Repository Decoder — app names/versions/issues from an arbitrary remote feed;
  * Repository Creator — a feed pulled in from a URL, then rendered as cards;
  * UDID Grabber       — attributes reported by the device;
  * Signer Console     — a certificate name from the phone, and chosen file names;
  * Certificate Check  — fields parsed out of an uploaded provisioning profile;
  * App Installer      — content type and redirect URLs from the probed host.

Without escaping, a malicious feed or device name executes script in the tool's
origin, which can then call the relay/admin endpoints. These tests check both
that the shared `esc()` helper actually neutralises markup (executed in Node when
available) and that every tool page still wires untrusted fields through it.

Run from `Services/API/server/`:

    python -m pytest tests/ -q
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

_TMP = tempfile.mkdtemp(prefix="vexsign-xss-test-")
os.environ.setdefault("VEXSIGN_DB", os.path.join(_TMP, "vexsign.db"))
os.environ.setdefault("REPO_STORE_DIR", os.path.join(_TMP, "store"))

import main  # noqa: E402
import web_chrome  # noqa: E402

PAYLOAD = '<img src=x onerror="alert(1)">'


@pytest.fixture
def client():
    with TestClient(main.app) as test_client:
        yield test_client


# ---------------------------------------------------------------------------
# The helper itself, executed rather than pattern-matched
# ---------------------------------------------------------------------------

TOOL_PAGES = (
    "/tools", "/Tools/udid", "/Tools/repo-decoder", "/Tools/signer",
    "/Tools/cert-check", "/Tools/repo-creator", "/Tools/app-installer",
)


def test_shared_helper_is_served_on_every_tool_page(client):
    for href in TOOL_PAGES:
        response = client.get(href)
        assert response.status_code == 200, href
        assert "const esc = " in response.text, href


@pytest.mark.skipif(shutil.which("node") is None, reason="node is not installed")
def test_esc_neutralises_markup_quotes_and_nullish_values():
    script = (
        web_chrome.SHARED_JS
        + "\nconst out = ["
        + "esc(process.argv[1]), esc('a&b'), esc('\"q\"'), esc(\"'s'\"),"
        + "esc(null), esc(undefined), esc(0), esc('plain text')"
        + "];\nconsole.log(JSON.stringify(out));"
    )
    result = subprocess.run(["node", "-e", script, "--", PAYLOAD],
                            capture_output=True, text=True, check=True)
    import json

    escaped, ampersand, quotes, apostrophe, nul, undef, zero, plain = json.loads(result.stdout)
    assert "<" not in escaped and ">" not in escaped
    assert "&lt;img" in escaped and "&quot;" in escaped
    assert ampersand == "a&amp;b"
    assert quotes == "&quot;q&quot;"
    assert apostrophe == "&#39;s&#39;"
    assert nul == "" and undef == ""
    assert zero == "0"
    assert plain == "plain text"


@pytest.mark.skipif(shutil.which("node") is None, reason="node is not installed")
def test_escaped_payload_cannot_create_an_element():
    # Render the payload through esc() into a fragment and confirm it stays text.
    script = web_chrome.SHARED_JS + """
const html = '<td>' + esc(process.argv[1]) + '</td>';
console.log(html.includes('<img') ? 'UNSAFE' : 'SAFE');
"""
    result = subprocess.run(["node", "-e", script, "--", PAYLOAD],
                            capture_output=True, text=True, check=True)
    assert result.stdout.strip() == "SAFE"


# ---------------------------------------------------------------------------
# Each tool routes its untrusted fields through esc()
# ---------------------------------------------------------------------------

def test_decoder_escapes_every_feed_derived_field(client):
    script = client.get("/Tools/repo-decoder").text
    for field in ("app.name", "app.bundleIdentifier", "app.version", "app.developerName",
                  "issue.app", "issue.message", "issue.suggestion", "issue.severity",
                  "error.message"):
        # Every interpolation of these fields must be wrapped, never bare.
        assert re.search(r"esc\(\s*" + re.escape(field), script), field
        assert not re.search(r"\+\s*" + re.escape(field) + r"\s*\+", script), field
    assert "esc(text)" in script          # pill()
    assert "esc(key)" in script           # normalised alias names


def test_udid_page_escapes_reported_device_attributes(client):
    script = client.get("/Tools/udid").text
    assert "esc(p[0])" in script and "esc(p[1])" in script
    assert "esc(data.device.DEVICE_UDID)" in script
    # The raw interpolations must be gone.
    assert "<td>${p[1]}</td>" not in script
    assert "<code>${data.device.DEVICE_UDID}</code>" not in script


def test_signer_console_escapes_certificate_and_file_names(client):
    script = client.get("/Tools/signer").text
    assert "esc(s.certName" in script
    assert "esc(job.name)" in script
    assert "esc(job.state.label)" in script
    assert "+ job.name +" not in script


def test_certificate_checker_escapes_profile_derived_values(client):
    script = client.get("/Tools/cert-check").text
    assert "<th>${esc(p[0])}</th><td>${esc(p[1])}</td>" in script
    assert "<td>${String(p[1])}</td>" not in script
    assert "esc(report.entitlementKeys.join(" in script
    assert "esc(data.revocation.note)" in script
    assert "esc(data.revocation.label)" in script
    assert "esc(error.message)" in script


def test_app_installer_escapes_probed_host_values(client):
    script = client.get("/Tools/app-installer").text
    for field in ("issue.severity", "issue.message", "issue.suggestion",
                  "body.probe.contentType", "body.contentType", "body.installLink",
                  "error.message"):
        assert re.search(r"esc\(" + re.escape(field), script), field
    assert "'<code>' + url + '</code>'" not in script   # redirect URLs
    assert "esc(url)" in script


def test_repository_creator_escapes_imported_feed_values(client):
    script = client.get("/Tools/repo-creator").text
    assert "esc(app.name || 'Untitled app')" in script
    assert "esc(app.bundleIdentifier || 'no bundle id')" in script
    # A feed can send a string where a number belongs; the attribute must hold it.
    assert 'value="${escapeAttr(app.size || 0)}"' in script
    assert 'value="${app.size || 0}"' not in script
    assert "return esc(value);" in script


# ---------------------------------------------------------------------------
# The page helpers themselves, executed against a payload
# ---------------------------------------------------------------------------

def _run_helper(page_source: str, start: str, call: str, setup: str = "") -> str:
    """Extract one page helper verbatim and run it in Node with the shared esc()."""
    begin = page_source.index(start)
    # Helpers are top-level `function name(...) { ... }` blocks ending at a
    # column-0 closing brace, which is how every one of these pages is written.
    end = page_source.index("\n}", begin) + 2
    script = (web_chrome.SHARED_JS + "\n" + setup + "\n"
              + page_source[begin:end] + "\n" + call)
    result = subprocess.run(["node", "-e", script, "--", PAYLOAD],
                            capture_output=True, text=True, check=True)
    return result.stdout.strip()


@pytest.mark.skipif(shutil.which("node") is None, reason="node is not installed")
def test_certificate_rows_helper_cannot_emit_an_element(client):
    source = client.get("/Tools/cert-check").text
    rendered = _run_helper(
        source, "function rows(",
        "console.log(rows([['TeamName', process.argv[1]], [process.argv[1], 'value']]));")
    assert "<img" not in rendered and "<script" not in rendered
    assert "&lt;img" in rendered


@pytest.mark.skipif(shutil.which("node") is None, reason="node is not installed")
def test_installer_issue_helper_cannot_emit_an_element(client):
    source = client.get("/Tools/app-installer").text
    rendered = _run_helper(
        source, "function issueRow(",
        "console.log(issueRow({severity: process.argv[1], message: process.argv[1],"
        " suggestion: process.argv[1]}));")
    assert "<img" not in rendered
    assert "&lt;img" in rendered


@pytest.mark.skipif(shutil.which("node") is None, reason="node is not installed")
def test_repository_card_helper_cannot_break_out_of_an_attribute(client):
    source = client.get("/Tools/repo-creator").text
    escape_attr = _run_helper(source, "function escapeAttr(",
                              "console.log(escapeAttr(process.argv[1]));")
    assert "<img" not in escape_attr and '"' not in escape_attr
    # The numeric field is the one a feed can smuggle a string into.
    assert "&quot;" in escape_attr


def test_page_chrome_still_escapes_server_side_title(client):
    # The shared chrome escapes on the Python side too; a title is module-supplied
    # but the guarantee should not regress.
    response = web_chrome.page("<script>x</script>", "body", request=None)
    assert "&lt;script&gt;" in response.body.decode()
    assert "<title><script>" not in response.body.decode()
