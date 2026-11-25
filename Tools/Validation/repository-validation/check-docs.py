#!/usr/bin/env python3
"""Offline checks for first-party documentation.

Two kinds of reference are checked:

1. Inline Markdown links/images — not remote URLs, HTML or heading anchors.
   Vendored documentation is outside this repository's ownership.

2. Repository paths written as *text* in tooling and workflows. These are the
   references the Markdown check cannot see: a release-note template or a gate
   message that names a path which has since moved. They rot silently and, in the
   release case, ship a 404 in every published release body.
"""
from pathlib import Path
import re
import sys
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[3]
LINK = re.compile(r'!?\[[^\]\n]*\]\(<?([^\s)>]+)>?(?:\s+"[^"\n]*")?\)')

# A repository path mentioned outside Markdown: one of the retained top-level
# documentation surfaces or the brand assets, always with a file extension.
DOC_REFERENCE = re.compile(
    r'(?<![\w/])((?:README|CONTRIBUTING|SECURITY|BRAND)\.md|'
    r'Docs/[A-Za-z0-9._/-]+\.(?:md|json|ya?ml|txt)|'
    r'Resources/brand/[A-Za-z0-9._/-]+\.(?:md|svg|png))'
)
REFERENCE_SCAN = ('.github/workflows/*.yml', 'Tools/**/*.py')
# Evidence files are produced by a device run and are never committed, so a
# reference to them is a documented output location, not a broken link.
REFERENCE_ALLOWLIST = ('Tools/Validation/security-validation/evidence/',)


def broken_links(root):
    files = sorted(root.glob('*.md'))
    scanned = []
    for directory in ('Documentation',):
        candidate = root / directory
        if candidate.is_dir():
            scanned.extend(sorted(candidate.rglob('*.md')))
    for path in scanned:
        if path not in files:
            files.append(path)
    for component in ('Services/WebManager', 'Services/Cloud',
                      'Services/Cloud/Anisette', 'Packages/NativeSigning',
                      'Services/Integrations', 'Packages/Vendor'):
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


def broken_references(root):
    """Documention paths named in tooling/workflows that do not exist."""
    candidates = []
    for pattern in REFERENCE_SCAN:
        candidates.extend(sorted(root.glob(pattern)))
    for path in candidates:
        # Test modules hold deliberately absent fixture paths on purpose, and
        # assert on them; they are not references.
        if path.name.startswith('test_') or path.name == 'test_docs.py':
            continue
        try:
            text = path.read_text(encoding='utf-8')
        except (OSError, UnicodeDecodeError):
            continue
        for match in DOC_REFERENCE.finditer(text):
            target = match.group(1)
            if any(prefix in target for prefix in REFERENCE_ALLOWLIST):
                continue
            if not (root / target).exists():
                where = path.relative_to(root).as_posix()
                yield f'{where}: references a missing path: {target}'


GUIDE_AREAS = ('Development', 'Architecture', 'Workflows', 'DeviceTesting')


if __name__ == '__main__':
    errors = list(broken_links(ROOT)) + list(broken_references(ROOT))
    print('\n'.join(errors) if errors else 'Documentation links: OK (offline; anchors/remote URLs not checked)')
    sys.exit(bool(errors))
