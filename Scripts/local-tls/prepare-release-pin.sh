#!/bin/bash
# Release trust comes from a reviewed committed pin or a protected environment
# variable. Never trust a freshly fetched pack merely because two fetches match.
set -euo pipefail
pin="Scripts/local-tls/pinned-pack.sha256"
python3 - "$pin" <<'PY'
import os
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
lines = [line.strip() for line in path.read_text().splitlines()
         if line.strip() and not line.lstrip().startswith('#')]
configured = os.environ.get('RELEASE_TLS_SHA256', '').strip().removeprefix('sha256:')
if configured and not re.fullmatch(r'[0-9a-f]{64}', configured):
    raise SystemExit('error: RELEASE_TLS_SHA256 must be a lowercase SHA-256 digest')
if lines:
    if len(lines) != 1 or not re.fullmatch(r'sha256:[0-9a-f]{64}', lines[0]):
        raise SystemExit('error: malformed or ambiguous committed TLS pin')
    if configured and lines[0] != 'sha256:' + configured:
        raise SystemExit('error: committed TLS pin and RELEASE_TLS_SHA256 disagree')
elif configured:
    path.write_text('# Approved release-environment TLS digest\nsha256:' + configured + '\n')
else:
    raise SystemExit('error: no approved release TLS digest. Review the Pin release TLS identity artifact, then set RELEASE_TLS_SHA256 in the release environment or commit the pin. Automatic first-use trust is disabled.')
PY
make deps-release
cp "$pin" "${RUNNER_TEMP:?RUNNER_TEMP must be set}/release-tls-pin.sha256"
