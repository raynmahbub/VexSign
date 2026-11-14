#!/usr/bin/env python3
"""Verify built IPA revision and write offline-verifiable provenance/checksums."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import zipfile


def generate(directory: Path, commit: str):
    if not re.fullmatch(r'[a-f0-9]{40}', commit):
        raise ValueError('A full Git source revision is required')
    files = sorted(directory.glob('*.ipa'))
    if not files:
        raise ValueError('No IPA found')
    artifacts = []
    for ipa in files:
        if ipa.is_symlink():
            raise ValueError('IPA must be a regular artifact, not a symlink')
        with zipfile.ZipFile(ipa) as archive:
            mains = [n for n in archive.namelist() if re.fullmatch(r'Payload/[^/]+\.app/Info\.plist', n)]
            if len(mains) != 1:
                raise ValueError('Expected exactly one primary app Info.plist')
            info = plistlib.loads(archive.read(mains[0]))
        if info.get('VexSignSourceCommit') != commit:
            raise ValueError('IPA source revision does not match the checked-out commit')
        with ipa.open('rb') as handle:
            digest = hashlib.file_digest(handle, 'sha256').hexdigest()
        artifacts.append(dict(name=ipa.name, sha256=digest, bytes=ipa.stat().st_size,
                              version=info.get('CFBundleShortVersionString'), build=info.get('CFBundleVersion')))
    manifest = dict(schema_version=1, source_commit=commit, unsigned=True, artifacts=artifacts,
                    workflow_run=os.environ.get('GITHUB_RUN_ID'), workflow_attempt=os.environ.get('GITHUB_RUN_ATTEMPT'))
    data = (json.dumps(manifest, indent=2, sort_keys=True) + '\n').encode()
    (directory / 'BUILD.json').write_bytes(data)
    checksums = [f'{a["sha256"]}  {a["name"]}\n' for a in artifacts]
    checksums.append(f'{hashlib.sha256(data).hexdigest()}  BUILD.json\n')
    (directory / 'SHA256SUMS').write_text(''.join(checksums))
    return manifest


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, required=True)
    args = parser.parse_args()
    commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
    generate(args.directory, commit)
