#!/usr/bin/env python3
"""Offline Markdown file-link check for first-party documentation.

Checks inline Markdown links/images, not remote URLs, HTML or heading anchors.
Vendored documentation is intentionally outside this repository's ownership.
"""
from pathlib import Path
import re
import sys
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[2]
LINK = re.compile(r'!?\[[^\]\n]*\]\(<?([^\s)>]+)>?(?:\s+"[^"\n]*")?\)')


def broken_links(root):
    files = sorted(root.glob('*.md'))
    scanned = []
    for directory in ('Documentation', 'docs'):
        candidate = root / directory
        if candidate.is_dir():
            scanned.extend(sorted(candidate.rglob('*.md')))
    # Deduplicate while preserving deterministic order.
    seen = set()
    for path in scanned:
        if path not in seen:
            files.append(path)
            seen.add(path)
    for component in ('Services/API/server', 'Services/CloudSigning/cloud-signing',
                      'Services/Anisette/AnisetteServer', 'Packages/NativeSigning',
                      'Integrations/EmbeddedContainer', 'Packages/Vendor'):
        path = root / component / 'README.md'
        if path.exists():
            files.append(path)
    for path in files:
        # Ignore examples inside fenced code blocks.
        text = re.sub(r'^```[^\n]*\n.*?^```[^\n]*$', '', path.read_text(),
                      flags=re.MULTILINE | re.DOTALL)
        for match in LINK.finditer(text):
            target = match.group(1)
            url = urlsplit(target)
            if url.scheme or url.netloc or not url.path:
                continue
            resolved = (path.parent / unquote(url.path)).resolve()
            if not resolved.is_relative_to(root.resolve()) or not resolved.exists():
                yield f'{path.relative_to(root)}: missing local target: {target}'


if __name__ == '__main__':
    errors = list(broken_links(ROOT))
    print('\n'.join(errors) if errors else 'Documentation file links: OK (offline; anchors/remote URLs not checked)')
    sys.exit(bool(errors))
