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


def _version_tuple(value):
    if not isinstance(value, str) or not re.fullmatch(r'[0-9]+(?:\.[0-9]+)*', value):
        raise ValueError(f'Invalid numeric iOS version: {value!r}')
    components = [int(component) for component in value.split('.')]
    return tuple(components + [0] * max(0, 3 - len(components)))


def verify_ipa(path, expected, expected_marketing_version=None,
               expected_bundle_identifier='com.vexsign.app', minimum_ios_version='17.0'):
    with zipfile.ZipFile(path) as archive:
        validate_container(archive)
        bundles = [name for name in archive.namelist()
                   if re.fullmatch(r'Payload/.*\.(?:app|appex)/Info\.plist', name)]
        roots = [name for name in bundles if len(Path(name).parts) == 3]
        if len(roots) != 1:
            raise ValueError('IPA must contain exactly one root app Info.plist')
        root_info = plistlib.loads(archive.read(roots[0]))
        if root_info.get('CFBundleIdentifier') != expected_bundle_identifier:
            raise ValueError('IPA root bundle identifier does not match the VexSign release configuration')
        if expected_marketing_version and root_info.get('CFBundleShortVersionString') != expected_marketing_version:
            raise ValueError('IPA root marketing version does not match the release version')
        if _version_tuple(root_info.get('MinimumOSVersion')) < _version_tuple(minimum_ios_version):
            raise ValueError(f'IPA minimum iOS version is below the supported {minimum_ios_version}')

        bundle_identifiers = set()
        for name in bundles:
            info = plistlib.loads(archive.read(name))
            actual_build = info.get('CFBundleVersion')
            if actual_build != expected:
                raise ValueError(f'{name}: CFBundleVersion does not match expected {expected}')
            identifier = info.get('CFBundleIdentifier')
            if not isinstance(identifier, str) or not identifier.startswith(expected_bundle_identifier + '.'):
                if name != roots[0] or identifier != expected_bundle_identifier:
                    raise ValueError(f'{name}: bundle identifier is outside the VexSign app namespace')
            if identifier in bundle_identifiers:
                raise ValueError(f'IPA contains duplicate app bundle identifier: {identifier}')
            bundle_identifiers.add(identifier)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    operation = parser.add_mutually_exclusive_group()
    operation.add_argument('--verify-ipa', type=Path)
    operation.add_argument('--check-container', type=Path)
    parser.add_argument('--expected-marketing-version')
    parser.add_argument('--expected-bundle-identifier', default='com.vexsign.app')
    parser.add_argument('--minimum-ios-version', default='17.0')
    args = parser.parse_args()
    if args.check_container:
        check_container(args.check_container)
        return
    count = int(subprocess.check_output(['git', 'rev-list', '--count', 'HEAD'], text=True).strip())
    expected = build_version(count)
    if args.verify_ipa:
        verify_ipa(
            args.verify_ipa,
            expected,
            expected_marketing_version=args.expected_marketing_version,
            expected_bundle_identifier=args.expected_bundle_identifier,
            minimum_ios_version=args.minimum_ios_version,
        )
    print(expected)


if __name__ == '__main__':
    main()
