#!/usr/bin/env python3
"""Offline checks for first-party documentation.

Two kinds of reference are checked:

1. Inline Markdown links/images in documentation — not remote URLs, HTML or
   heading anchors. Vendored documentation is outside this repository's ownership.

2. `Documentation/...` paths written as *text* in tooling and workflows. These
   are the references the Markdown check cannot see: a release-note template or a
   gate message that names a path which has since moved. They rot silently and,
   in the release case, ship a 404 in every published release body.
"""
from pathlib import Path
import re
import sys
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[4]
LINK = re.compile(r'!?\[[^\]\n]*\]\(<?([^\s)>]+)>?(?:\s+"[^"\n]*")?\)')

# A documentation path mentioned outside Markdown: optionally prefixed with the
# repository directory, and always with a file extension.
DOC_REFERENCE = re.compile(
    r'(?<![\w/])((?:VexSign/)?Documentation/[A-Za-z0-9._/-]+\.(?:md|svg|png|json|ya?ml|txt))'
)
REFERENCE_SCAN = ('.github/workflows/*.yml', 'VexSign/Tools/**/*.py')
# Evidence files are produced by a device run and are never committed, so a
# reference to them is a documented output location, not a broken link.
REFERENCE_ALLOWLIST = ('VexSign/Documentation/DeviceTesting/evidence/',)


def broken_links(root):
    files = sorted(root.glob('*.md'))
    scanned = []
    for directory in ('VexSign/Documentation',):
        candidate = root / directory
        if candidate.is_dir():
            scanned.extend(sorted(candidate.rglob('*.md')))
    # Deduplicate while preserving deterministic order.
    seen = set()
    for path in scanned:
        if path not in seen:
            files.append(path)
            seen.add(path)
    for component in ('VexSign/Services/WebManager', 'VexSign/Services/Cloud',
                      'VexSign/Services/Cloud/Anisette', 'VexSign/Packages/NativeSigning',
                      'VexSign/Integrations', 'VexSign/Packages/Vendor'):
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


def unreferenced_guides(root):
    """Guides that no other document, workflow or tool names.

    `broken_links` answers "does this link resolve"; nothing answered "can this
    document be found at all". The four guide directories are read by people who
    arrived from the index, so a file there that no other text mentions is a file
    only its author knows about. Review history, release notes and the DocC
    catalogue are outside this: they are referenced by the process that writes
    them, not by a link from a sibling page.
    """
    docs = root / 'VexSign/Documentation'
    sources = list(root.glob('*.md'))
    for pattern in ('VexSign/Documentation/**/*.md', '.github/**/*.yml', 'VexSign/Tools/**/*.py'):
        sources.extend(sorted(root.glob(pattern)))
    # Test modules name deliberately missing fixtures; they are not references.
    sources = [p for p in sources if not p.name.startswith('test_')]
    texts = {}
    for path in sources:
        try:
            texts[path] = path.read_text(encoding='utf-8')
        except (OSError, UnicodeDecodeError):
            continue
    for area in GUIDE_AREAS:
        for path in sorted((docs / area).rglob('*.md')):
            name = path.name
            others = [text for other, text in texts.items() if other != path]
            if not any(name in text for text in others):
                yield f'{path.relative_to(root).as_posix()}: not referenced from any other document'


if __name__ == '__main__':
    errors = list(broken_links(ROOT)) + list(broken_references(ROOT)) + list(unreferenced_guides(ROOT))
    print('\n'.join(errors) if errors else 'Documentation links: OK (offline; anchors/remote URLs not checked)')
    sys.exit(bool(errors))
