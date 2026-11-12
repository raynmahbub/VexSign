#!/usr/bin/env python3
"""Generate/check explicit human device acceptance; never simulates a device pass."""
import argparse
import hashlib
import json
import os
import plistlib
import zipfile
from pathlib import Path
import re
import subprocess


class CommitUnavailable(RuntimeError):
    """No commit can be established, so a report could not be bound to source.

    Raised instead of returning an empty string: a report whose `commit` is blank would
    validate against an empty expectation, which is the opposite of the integrity check
    this tool exists for.
    """


def resolve_commit(explicit=None, environ=None):
    """The commit a report is bound to.

    Priority is explicit `--commit`, then `VEXSIGN_SOURCE_COMMIT`/`GITHUB_SHA` (CI has the
    commit but a source archive has no `.git`), then `git rev-parse HEAD`.

    An unpacked archive is the case this ordering fixes: `make verify` runs from a zip with
    no VCS metadata, so the git call used to end in an uncaught `fatal: not a git
    repository` traceback. CI still resolves a real commit, and a caller with neither
    metadata nor an argument gets a one-line diagnostic naming both remedies rather than
    a stack trace.
    """
    environ = os.environ if environ is None else environ

    candidate = (explicit or '').strip()
    if not candidate:
        for key in ('VEXSIGN_SOURCE_COMMIT', 'GITHUB_SHA'):
            candidate = environ.get(key, '').strip()
            if candidate:
                break

    if not candidate:
        try:
            candidate = subprocess.check_output(
                ['git', 'rev-parse', 'HEAD'], text=True, stderr=subprocess.DEVNULL, env=environ
            ).strip()
        except (OSError, subprocess.CalledProcessError):
            candidate = ''

    if not re.fullmatch(r'[0-9a-fA-F]{40}|[0-9a-fA-F]{64}', candidate):
        raise CommitUnavailable(
            'No source commit could be established. Run from a git checkout, pass '
            '--commit <sha>, or set VEXSIGN_SOURCE_COMMIT (or GITHUB_SHA in CI). '
            'A report is never written without the commit it attests.'
        )

    # Lowercase so a short-form SHA handed in by a caller still compares like git's output.
    return candidate.lower()

CASES = ('launch', 'import_sign_verify', 'trust_profile', 'offline_local_install',
         'installed_version', 'relaunch_persistence', 'update_persistence',
         'renewal_preserves_ca', 'explicit_rotation', 'locked_device_failure',
         'cancel_and_timeout', 'invalid_profile_rejected')


NATIVE_PRIMARY_CASES = ('native_primary_bootstrap', 'host_session_switches',
                        'single_guest_boundary', 'primary_keychain_guard',
                        'installed_inventory_evidence', 'v3_provider_explicit_consent',
                        'cms_quota_gate', 'native_owned_sign_install',
                        'scoped_unattended_renewal')


# Free Apple ID → certificate-store handoff ladder, step 5 of
# docs/NATIVE_SIGNING_HANDOFF.md. These are recorded only when a device run
# actually exercised the native account flow (`init --include-native-handoff`);
# `tools/native-promotion-evidence.py` requires every one of them, plus genuine
# Apple-issued CMS evidence, before
# SigningMethodCapabilities.nativeAppleAccountSigning may claim `.implemented`.
NATIVE_HANDOFF_CASES = ('native_sign_in_team_selection', 'native_device_and_app_id_registration',
                        'native_profile_creation_and_export', 'native_key_export_consent_import',
                        'native_signed_output_verification', 'native_install_and_relaunch',
                        'native_seven_day_expiry_observed',
                        'native_identity_persistence_after_relaunch')


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
    if report.get('native_handoff') not in (None, True):
        errors.append('native_handoff must be true or absent')
    required = required_cases(architecture)
    if report.get('native_handoff') is True:
        required += NATIVE_HANDOFF_CASES
    elif any(case in cases for case in NATIVE_HANDOFF_CASES):
        # A partially recorded ladder reads like a partial pass. Either the run
        # exercised the native handoff or it did not.
        errors.append('native handoff checks recorded without native_handoff: true')
    for case in required:
        item = cases.get(case, {})
        if not isinstance(item, dict) or item.get('result') != 'pass' or not isinstance(item.get('notes'), str) or not item['notes'].strip():
            errors.append(f'{case}: requires explicit pass and observation notes')
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=('init', 'check'))
    parser.add_argument('--ipa', required=True, type=Path)
    parser.add_argument('--report', required=True, type=Path)
    parser.add_argument('--commit', help='Source commit to bind the report to. Defaults to '
                                        'VEXSIGN_SOURCE_COMMIT/GITHUB_SHA, then git HEAD.')
    parser.add_argument('--include-native-handoff', action='store_true',
                        help='init: also record the Free Apple ID handoff ladder cases')
    args = parser.parse_args()
    if args.mode == 'check' and args.include_native_handoff:
        parser.exit(1, '--include-native-handoff applies to init only; a report declares itself\n')

    try:
        commit = resolve_commit(args.commit)
    except CommitUnavailable as error:
        # A diagnostic, not a traceback: this is an expected state when the tool runs
        # from a source archive.
        parser.exit(2, f'error: {error}\n')

    digest = hashlib.file_digest(args.ipa.open('rb'), 'sha256').hexdigest()
    try:
        architecture = artifact_architecture(args.ipa)
    except (ValueError, plistlib.InvalidFileException, zipfile.BadZipFile) as error:
        parser.exit(1, str(error) + '\n')
    if args.mode == 'init':
        cases = required_cases(architecture)
        if args.include_native_handoff:
            cases += NATIVE_HANDOFF_CASES
        report = dict(architecture=architecture, commit=commit, ipa_sha256=digest, tester='', device_model='',
                      os_version='', tested_at_utc='', checks={
                          case: dict(result='pending', notes='') for case in cases})
        if args.include_native_handoff:
            report['native_handoff'] = True
        with args.report.open('x') as handle:
            json.dump(report, handle, indent=2)
            handle.write('\n')
        print('Pending report created. No device checks have passed.'
              + (' Native handoff ladder included.' if args.include_native_handoff else ''))
        return
    errors = validate(json.loads(args.report.read_text()), commit, digest, architecture)
    if errors:
        parser.exit(1, '\n'.join(errors) + '\n')
    print('Human acceptance report complete for this commit/artifact. This is an attestation, not independent device verification.')


if __name__ == '__main__':
    main()
