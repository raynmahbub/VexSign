#!/usr/bin/env python3
"""Generate/check explicit human device acceptance; never simulates a device pass."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

CASES = ('launch', 'import_sign_verify', 'trust_profile', 'offline_local_install',
         'installed_version', 'relaunch_persistence', 'update_persistence',
         'renewal_preserves_ca', 'explicit_rotation', 'locked_device_failure',
         'cancel_and_timeout', 'invalid_profile_rejected')


def validate(report, commit, digest):
    errors = []
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
    for case in CASES:
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
    if args.mode == 'init':
        report = dict(commit=commit, ipa_sha256=digest, tester='', device_model='',
                      os_version='', tested_at_utc='', checks={
                          case: dict(result='pending', notes='') for case in CASES})
        with args.report.open('x') as handle:
            json.dump(report, handle, indent=2)
            handle.write('\n')
        print('Pending report created. No device checks have passed.')
        return
    errors = validate(json.loads(args.report.read_text()), commit, digest)
    if errors:
        parser.exit(1, '\n'.join(errors) + '\n')
    print('Human acceptance report complete for this commit/artifact. This is an attestation, not independent device verification.')


if __name__ == '__main__':
    main()
