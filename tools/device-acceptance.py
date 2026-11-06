#!/usr/bin/env python3
"""Generate/check explicit human device acceptance; never simulates a device pass."""
import argparse
import hashlib
import json
import plistlib
import zipfile
from pathlib import Path
import re
import subprocess

CASES = ('launch', 'import_sign_verify', 'trust_profile', 'offline_local_install',
         'installed_version', 'relaunch_persistence', 'update_persistence',
         'renewal_preserves_ca', 'explicit_rotation', 'locked_device_failure',
         'cancel_and_timeout', 'invalid_profile_rejected')


NATIVE_PRIMARY_CASES = ('native_primary_bootstrap', 'host_session_switches',
                        'single_guest_boundary', 'primary_keychain_guard',
                        'installed_inventory_evidence', 'v3_provider_explicit_consent',
                        'cms_quota_gate', 'native_owned_sign_install',
                        'scoped_unattended_renewal')


def artifact_architecture(ipa):
    """Classify metadata only, not code trust or successful native execution."""
    with zipfile.ZipFile(ipa) as archive:
        candidates = [item for item in archive.infolist()
                      if len(Path(item.filename).parts) == 3
                      and Path(item.filename).parts[0] == 'Payload'
                      and Path(item.filename).parts[1].endswith('.app')
                      and Path(item.filename).parts[2] == 'Info.plist']
        if len(candidates) != 1 or not 0 < candidates[0].file_size <= 1024 * 1024:
            raise ValueError('Expected exactly one bounded root app Info.plist')
        info = plistlib.loads(archive.read(candidates[0]))
    if not isinstance(info, dict):
        raise ValueError('Invalid root app metadata')
    if info.get('VexSignPrimaryHost') is True:
        if info.get('VexSignCombinedHost') is not True or info.get('VexSignEmbeddedGuest') is True:
            raise ValueError('Inconsistent native primary metadata')
        return 'native-primary'
    if info.get('VexSignCombinedHost') is True:
        return 'guest-prototype'
    if info.get('VexSignEmbeddedGuest') is True:
        raise ValueError('A staged guest is not a standalone or combined host artifact')
    return 'standalone'


def required_cases(architecture):
    return CASES + NATIVE_PRIMARY_CASES if architecture == 'native-primary' else CASES


def validate(report, commit, digest, architecture='standalone'):
    errors = []
    if architecture not in ('standalone', 'native-primary', 'guest-prototype'):
        errors.append('Unsupported artifact architecture')
    if report.get('architecture', 'standalone') != architecture:
        errors.append('Report architecture differs from supplied artifact')
    if report.get('commit') != commit:
        errors.append('Report commit differs from checkout')
    if report.get('ipa_sha256') != digest:
        errors.append('Report IPA checksum differs from supplied artifact')
    for key in ('tester', 'device_model', 'os_version', 'tested_at_utc'):
        if not isinstance(report.get(key), str) or not report[key].strip():
            errors.append(f'Missing {key}')
    if not re.fullmatch(r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ', report.get('tested_at_utc', '')):
        errors.append('tested_at_utc must use YYYY-MM-DDTHH:MM:SSZ')
    cases = report.get('checks', {})
    if not isinstance(cases, dict):
        return errors + ['checks must be an object']
    for case in required_cases(architecture):
        item = cases.get(case, {})
        if not isinstance(item, dict) or item.get('result') != 'pass' or not isinstance(item.get('notes'), str) or not item['notes'].strip():
            errors.append(f'{case}: requires explicit pass and observation notes')
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=('init', 'check'))
    parser.add_argument('--ipa', required=True, type=Path)
    parser.add_argument('--report', required=True, type=Path)
    args = parser.parse_args()
    commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
    digest = hashlib.file_digest(args.ipa.open('rb'), 'sha256').hexdigest()
    try:
        architecture = artifact_architecture(args.ipa)
    except (ValueError, plistlib.InvalidFileException, zipfile.BadZipFile) as error:
        parser.exit(1, str(error) + '\n')
    if args.mode == 'init':
        report = dict(architecture=architecture, commit=commit, ipa_sha256=digest, tester='', device_model='',
                      os_version='', tested_at_utc='', checks={
                          case: dict(result='pending', notes='') for case in required_cases(architecture)})
        with args.report.open('x') as handle:
            json.dump(report, handle, indent=2)
            handle.write('\n')
        print('Pending report created. No device checks have passed.')
        return
    errors = validate(json.loads(args.report.read_text()), commit, digest, architecture)
    if errors:
        parser.exit(1, '\n'.join(errors) + '\n')
    print('Human acceptance report complete for this commit/artifact. This is an attestation, not independent device verification.')


if __name__ == '__main__':
    main()
