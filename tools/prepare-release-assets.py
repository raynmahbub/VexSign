#!/usr/bin/env python3
"""Create offline, commit-pinned release notes, metadata, visuals and checksums."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def prepare(output, version, channel, repository):
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository):
        raise ValueError('Expected owner/repository')
    if not re.fullmatch(r'\d+\.\d+(?:\.\d+)?(?:-[A-Za-z0-9.]+)?', version):
        raise ValueError('Invalid release version')
    ipas = sorted(output.glob('*.ipa'))
    if len(ipas) != 1:
        raise ValueError('Exactly one built IPA is required')
    commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    raw = f'https://raw.githubusercontent.com/{repository}/{commit}'
    notes = subprocess.check_output(['bash', 'tools/generate-changelog.sh'], cwd=ROOT,
                                    env={**os.environ, 'VERSION': version}, text=True)
    warning = ('Experimental pre-release; may contain regressions. Does not update the stable source listing.'
               if channel != 'stable' else 'Stable channel. The unsigned IPA still requires a valid signing identity.')
    intro = (f'![VexSign app icon]({raw}/icon.png)\n\n'
             f'> **{channel.title()}** — {warning}\n\n'
             f'Commit: [`{commit[:7]}`](https://github.com/{repository}/commit/{commit}) · '
             f'[Install and platform limits]({raw}/docs/PLATFORMS.md)\n\n'
             '### Install and verify\n\nDownload the IPA below, verify it against `SHA256SUMS`, then sign it with your own identity. '
             'Do not import certificates from release attachments. See `RELEASE.json` for artifact provenance.\n\n')
    # Optional, reviewed, version-specific highlights; never machine-invented claims.
    highlights = ROOT / 'docs/releases' / f'{version.split("-")[0]}.md'
    if highlights.exists():
        intro += '### Release highlights\n\n' + highlights.read_text().strip() + '\n\n'
    ending = (f'\n### Interface preview\n\n[Home layout preview]({raw}/docs/assets/home-preview.svg) '
              'is a design illustration, **not a screenshot or proof of device testing**. '
              'The app icon and preview are also attached.\n')
    (output / 'CHANGELOG.md').write_text(intro + notes + ending)
    shutil.copyfile(ROOT / 'icon.png', output / 'VexSign-icon.png')
    shutil.copyfile(ROOT / 'docs/assets/home-preview.svg', output / 'Home-layout-preview.svg')
    with ipas[0].open('rb') as handle:
        digest = hashlib.file_digest(handle, 'sha256').hexdigest()
    metadata = dict(schema_version=1, version=version, channel=channel, repository=repository,
                    commit=commit, unsigned=True, ipa=dict(name=ipas[0].name, sha256=digest),
                    workflow_run=os.environ.get('GITHUB_RUN_ID'),
                    workflow_attempt=os.environ.get('GITHUB_RUN_ATTEMPT'),
                    visuals='App icon and design illustration; not device screenshots')
    (output / 'RELEASE.json').write_text(json.dumps(metadata, indent=2) + '\n')
    names = [ipas[0].name, 'CHANGELOG.md', 'RELEASE.json', 'VexSign-icon.png', 'Home-layout-preview.svg']
    sums = []
    for name in names:
        with (output / name).open('rb') as handle:
            sums.append(f'{hashlib.file_digest(handle, "sha256").hexdigest()}  {name}\n')
    (output / 'SHA256SUMS').write_text(''.join(sums))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--version', required=True)
    parser.add_argument('--channel', required=True, choices=('stable', 'nightly', 'prerelease'))
    parser.add_argument('--repository', required=True)
    args = parser.parse_args()
    prepare(args.output, args.version, args.channel, args.repository)
