"""Browser signer relay authentication, escaping and retry behavior."""
from __future__ import annotations

import json
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "API"))
import web_chrome  # noqa: E402
import web_signer  # noqa: E402


@pytest.mark.skipif(shutil.which("node") is None, reason="node is not installed")
def test_signer_browser_sends_relay_token_escapes_status_and_retries_failures():
    harness = r"""
const elements = {};
function element(id) {
  if (!elements[id]) elements[id] = { value: '', innerHTML: '', disabled: false,
    appendChild() {}, prepend() {}, remove() {}, click() {}, style: {} };
  return elements[id];
}
global.document = { getElementById: element, createElement: () => element('created'),
  body: element('body'), addEventListener() {} };
element('base').value = 'http://192.168.1.20:8000';
element('relay-token').value = 'relay-secret';
element('token').value = 'phone-secret';
let fetchOptions;
global.fetch = async (_url, options) => {
  fetchOptions = options;
  return { ok: true, json: async () => ({ latencyMs: '<img src=x>', data: {
    certValid: true, certDaysRemaining: 4, certName: 'test',
    installedApps: '<img src=x onerror=alert(1)>', signedApps: 2, pendingUpdates: 3
  }}) };
};
global.FormData = class { append() {} };
const statuses = [500, 200];
const headers = [];
let clearDisabledDuringSend = true;
global.XMLHttpRequest = class {
  constructor() { this.upload = {}; this.headers = {}; }
  open() {}
  setRequestHeader(name, value) { this.headers[name] = value; }
  send() {
    headers.push(this.headers);
    clearDisabledDuringSend &&= element('clear').disabled;
    this.status = statuses.shift();
    this.response = { text: async () => JSON.stringify({detail: 'retry'}) };
    this.onload();
  }
};
URL.createObjectURL = () => 'blob:fixture';
URL.revokeObjectURL = () => {};
global.setTimeout = () => 0;
"""
    script = web_signer.PAGE_SCRIPT.replace("<script>", "").replace("</script>", "")
    exercise = r"""
(async () => {
  await connect();
  queue.push({ file: {}, name: 'test.ipa', size: 10, done: false,
    state: {label: 'queued', pill: 'idle'} });
  await runQueue();
  const afterFailure = queue[0].done;
  await runQueue();
  console.log(JSON.stringify({ fetchOptions, headers, afterFailure,
    afterRetry: queue[0].done, clearDisabledDuringSend,
    clearDisabledAfter: element('clear').disabled, status: element('status').innerHTML }));
})().catch(error => { console.error(error); process.exit(1); });
"""
    result = subprocess.run(["node", "-e", harness + web_chrome.SHARED_JS + script + exercise],
                            capture_output=True, text=True, check=True)
    output = json.loads(result.stdout)
    assert output["fetchOptions"]["headers"]["X-Relay-Token"] == "relay-secret"
    assert json.loads(output["fetchOptions"]["body"])["token"] == "phone-secret"
    assert "relay-secret" not in output["fetchOptions"]["body"]
    assert [item["X-Relay-Token"] for item in output["headers"]] == ["relay-secret", "relay-secret"]
    assert output["afterFailure"] is False
    assert output["afterRetry"] is True
    assert output["clearDisabledDuringSend"] is True
    assert output["clearDisabledAfter"] is False
    assert "<img" not in output["status"]
    assert "&lt;img" in output["status"]
