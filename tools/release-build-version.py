#!/usr/bin/env python3
"""Deterministic Apple-compatible build numbers and packaged-IPA validation."""
import argparse
from pathlib import Path
import plistlib
import re
import subprocess
import zipfile


def build_version(commit_count):
    # Full-history reachable commit count increases on main. Split it into
    # Apple's four/two/two digit components; keep source SHA in RELEASE.json.
    if not 1 <= commit_count <= 99989999:
        raise ValueError('Commit count is outside the supported build-version range')
    return f'{1 + commit_count // 10000}.{commit_count // 100 % 100}.{commit_count % 100}'


def validate_container(archive):
    """Check the bytes being published, not just the staged app's metadata."""
    names = archive.namelist()
    if len(names) != len(set(names)):
        raise ValueError('IPA contains duplicate archive member names')
    roots = [name for name in names if re.fullmatch(r'Payload/[^/]+\.app/Info\.plist', name)]
    if len(roots) != 1:
        raise ValueError('IPA must contain exactly one root app Info.plist')
    try:
        bad = archive.testzip()
    except (zipfile.BadZipFile, RuntimeError) as error:
        raise ValueError('IPA member validation failed') from error
    if bad is not None:
        raise ValueError(f'IPA contains a corrupt member: {bad}')


def check_container(path):
    with zipfile.ZipFile(path) as archive:
        validate_container(archive)


def verify_ipa(path, expected):
    with zipfile.ZipFile(path) as archive:
        validate_container(archive)
        bundles = [name for name in archive.namelist()
                   if re.fullmatch(r'Payload/.*\.(?:app|appex)/Info\.plist', name)]
        roots = [name for name in bundles if len(Path(name).parts) == 3]
        if len(roots) != 1:
            raise ValueError('IPA must contain exactly one root app Info.plist')
        for name in bundles:
            actual = plistlib.loads(archive.read(name)).get('CFBundleVersion')
            if actual != expected:
                raise ValueError(f'{name}: CFBundleVersion does not match expected {expected}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    operation = parser.add_mutually_exclusive_group()
    operation.add_argument('--verify-ipa', type=Path)
    operation.add_argument('--check-container', type=Path)
    args = parser.parse_args()
    if args.check_container:
        check_container(args.check_container)
        return
    count = int(subprocess.check_output(['git', 'rev-list', '--count', 'HEAD'], text=True).strip())
    expected = build_version(count)
    if args.verify_ipa:
        verify_ipa(args.verify_ipa, expected)
    print(expected)


if __name__ == '__main__':
    main()
