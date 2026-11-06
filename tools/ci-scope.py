#!/usr/bin/env python3
"""Skip native CI only for a fully known, portable-tool/documentation-only diff.

Use the complete PR diff against its base, never just the latest commit. Unknown
paths, missing history, first pushes and manual full validation fail open to
running native checks, not to silently declaring untested app code validated.
"""
import json
import os
from pathlib import Path, PurePosixPath
import subprocess


def needs_native(paths):
    for name in paths:
        path = PurePosixPath(name)
        portable = (name.endswith('.md') or name.startswith('docs/') or
                    (name.startswith('tools/') and path.suffix == '.py') or
                    name == 'tools/generate-changelog.sh')
        if not portable:
            return True
    return False


def main():
    native = True
    if os.environ.get('GITHUB_EVENT_NAME') in ('pull_request', 'push'):
        try:
            event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
            base = event['pull_request']['base']['sha'] if 'pull_request' in event else event['before']
            if len(base) != 40 or any(c not in '0123456789abcdef' for c in base) or base == '0' * 40:
                raise ValueError('Missing immutable base')
            changes = subprocess.check_output(['git', 'diff', '--name-only', '--no-renames', '-z', base, 'HEAD'])
            native = needs_native([p.decode('utf-8') for p in changes.split(b'\0') if p])
        except (KeyError, ValueError, OSError, subprocess.CalledProcessError, UnicodeError):
            native = True
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        output.write(f'native={str(native).lower()}\n')
    print('Native CI required' if native else 'Portable-only diff: native jobs not required')


if __name__ == '__main__':
    main()
