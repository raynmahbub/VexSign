#!/usr/bin/env python3
"""Generate/check explicit human device acceptance; never simulates a device pass."""
from datetime import datetime, timedelta
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


# On-device bootstrap acceptance. These cases describe what a human must
# observe when the *unmodified* build is placed on a phone and VexSign completes
# the guided bootstrap without a computer. They are opt-in: a report that did not
# exercise this route must not acquire these passes by accident, and a partial set
# reads as no result at all.
BOOTSTRAP_CASES = (
    'bootstrap_accepts_unmodified_ipa',
    'bootstrap_no_computer_or_existing_pairing_file',
    'bootstrap_host_advertised_with_pin_confirmation',
    'bootstrap_device_identity_verified',
    'bootstrap_account_authorization_confirmed',
    'bootstrap_install_request_confirmed_on_device',
    'bootstrap_installed_app_launches',
    'bootstrap_cancel_recovery',
    'bootstrap_network_failure_recovery',
)

# The report must name the exact artifact, record and target. These fields are
# observations, not derived values: a report writer cannot reconstruct them from
# the IPA checksum or from source inspection.
BOOTSTRAP_EVIDENCE = {
    'pairing_route': r'ondevice-host',
    'pairing_fingerprint_sha256': r'[a-f0-9]{64}',
    'device_udid': r'(?:[A-F0-9]{8}-[A-F0-9]{16}|[A-F0-9]{40})',
    'installed_bundle_id': r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+',
    'installed_version': r'.{1,64}',
}


def bootstrap_evidence_errors(evidence):
    """Validate the structured bootstrap observations; never infer them."""
    if not isinstance(evidence, dict):
        return ['bootstrap evidence: object required']
    errors = []
    for key, pattern in BOOTSTRAP_EVIDENCE.items():
        value = evidence.get(key)
        if not isinstance(value, str) or not re.fullmatch(pattern, value):
            errors.append(f'bootstrap evidence.{key}: missing or malformed observation')
    # A computer-free run cannot claim to have imported a pairing file. The
    # `computer_free_bootstrap` declaration and the evidence must agree.
    if evidence.get('pairing_route') not in (None, 'ondevice-host'):
        errors.append('bootstrap evidence.pairing_route: not a computer-free route')
    return errors


# Apple Account lifecycle. Opt-in and strictly separate from the native
# handoff ladder used for capability promotion: a report can exercise a full
# lifecycle without claiming an in-process CMS signer, and vice versa.
APPLE_ACCOUNT_LIFECYCLE_CASES = (
    'account_free_and_paid_teams_observed',
    'account_two_factor_challenge_confirmed',
    'account_certificate_and_profile_created',
    'account_free_quota_observed',
    'account_signed_artifact_installed',
    'account_seven_day_expiry_observed',
    'account_manual_renewal_advances_expiry',
    'account_cancel_and_retry_recovers',
)

APPLE_ACCOUNT_EVIDENCE = {
    'account_kind': r'free|paid',
    'team_identifier': r'[A-Z0-9]{10}',
    'profile_uuid': r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}',
    'profile_expires_utc': r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ',
    'signed_ipa_sha256': r'[a-f0-9]{64}',
    'installed_bundle_id': r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+',
    'install_receipt': r'.{1,128}',
    'active_app_id_count': r'\d{1,3}',
    'registered_device_count': r'\d{1,3}',
}


def apple_account_evidence_errors(evidence, report):
    """Validate Apple Account observations and Apple's free-account constraints."""
    if not isinstance(evidence, dict):
        return ['apple_account evidence: object required']
    errors = []
    for key, pattern in APPLE_ACCOUNT_EVIDENCE.items():
        value = evidence.get(key)
        if not isinstance(value, str) or not re.fullmatch(pattern, value):
            errors.append(f'apple_account evidence.{key}: missing or malformed observation')
    if errors:
        return errors  # Do not interpret fields that are not well formed.
    if evidence['account_kind'] != 'free':
        return errors  # Paid profiles are issued on a different cadence.
    # Apple Developer > Developer account overview (Personal Team): up to
    # 10 App IDs and 3 devices, each registered for 7 days, plus up to 3
    # installed apps per device. These are observed portal counts, not local
    # VexSign profile receipts.
    if int(evidence['active_app_id_count']) > 10:
        errors.append('apple_account evidence.active_app_id_count: free account exceeds ten App IDs')
    if int(evidence['registered_device_count']) > 3:
        errors.append('apple_account evidence.registered_device_count: free account exceeds three devices')
    try:
        observed = datetime.strptime(report.get('tested_at_utc', ''), '%Y-%m-%dT%H:%M:%SZ')
        expires = datetime.strptime(evidence['profile_expires_utc'], '%Y-%m-%dT%H:%M:%SZ')
    except (TypeError, ValueError):
        return errors + ['apple_account evidence.profile_expires_utc: not a comparable UTC timestamp']
    lifetime = expires - observed
    if lifetime.total_seconds() <= 0 or lifetime > timedelta(days=8):
        errors.append('apple_account evidence.profile_expires_utc: free profile is not a seven-day observation')
    return errors


# Paired installation. This ladder is opt-in and separate from both the
# bootstrap and Apple Account ladders: a report must declare
# that this exact IPA was exercised over an admitted pairing route. It does not
# unlock the vendored installation bridge; that gate changes only after a real
# device run and the existing security evidence gates are satisfied.
PAIRED_INSTALLATION_CASES = (
    'paired_route_and_bridge_admitted',
    'paired_record_fingerprint_matches_device_query',
    'paired_signed_artifact_validated',
    'paired_install_request_accepted',
    'paired_exact_version_confirmed',
    'paired_app_launch_observed',
    'paired_timeout_leaves_outcome_unknown',
    'paired_cancel_and_retry_recovers',
)

PAIRED_INSTALLATION_EVIDENCE = {
    'pairing_route': r'imported-classic|ondevice-host',
    'pairing_fingerprint_sha256': r'[a-f0-9]{64}',
    'device_udid': r'(?:[A-F0-9]{8}-[A-F0-9]{16}|[A-F0-9]{40})',
    'package_sha256': r'[a-f0-9]{64}',
    'install_receipt': r'.{1,128}',
    'confirmation_receipt': r'.{1,128}',
    'installed_bundle_id': r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+',
    'installed_version': r'.{1,64}',
    'submitted_at_utc': r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ',
    'confirmed_at_utc': r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ',
}


def paired_installation_evidence_errors(evidence, report):
    """Validate paired-installation observations; no inferred or synthetic install passes."""
    if not isinstance(evidence, dict):
        return ['paired_installation evidence: object required']
    errors = []
    for key, pattern in PAIRED_INSTALLATION_EVIDENCE.items():
        value = evidence.get(key)
        if not isinstance(value, str) or not re.fullmatch(pattern, value):
            errors.append(f'paired_installation evidence.{key}: missing or malformed observation')
    if errors:
        return errors  # Do not interpret fields that are not well formed.
    if evidence['package_sha256'] != report.get('ipa_sha256'):
        errors.append('paired_installation evidence.package_sha256: not this exact IPA')
    if evidence['install_receipt'] == evidence['confirmation_receipt']:
        errors.append('paired_installation evidence.confirmation_receipt: command acknowledgement is not installed-app evidence')
    try:
        submitted = datetime.strptime(evidence['submitted_at_utc'], '%Y-%m-%dT%H:%M:%SZ')
        confirmed = datetime.strptime(evidence['confirmed_at_utc'], '%Y-%m-%dT%H:%M:%SZ')
        tested = datetime.strptime(report.get('tested_at_utc', ''), '%Y-%m-%dT%H:%M:%SZ')
    except (TypeError, ValueError):
        return errors + ['paired_installation evidence timestamps: not comparable UTC timestamps']
    if confirmed < submitted:
        errors.append('paired_installation evidence.confirmed_at_utc: confirmation precedes submission')
    if confirmed > tested:
        errors.append('paired_installation evidence.confirmed_at_utc: observation is after the report timestamp')
    return errors


NATIVE_PRIMARY_CASES = ('native_primary_bootstrap', 'host_session_switches',
                        'single_guest_boundary', 'primary_keychain_guard',
                        'installed_inventory_evidence', 'v3_provider_explicit_consent',
                        'cms_quota_gate', 'native_owned_sign_install',
                        'scoped_unattended_renewal')


# Free Apple ID → certificate-store handoff ladder, step 5 of
# README.md#declared-capabilities-and-their-limits. These are recorded only when a device run
# actually exercised the native account flow (`init --include-native-handoff`);
# `Tools/Validation/security-validation/native-promotion-evidence.py` requires every one of them, plus genuine
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


def renewal_template():
    return {stage: dict(bundle_id='', team_id='', profile_expires_utc='', marker_sha256='')
            for stage in ('before', 'after')}


def renewal_errors(evidence):
    if not isinstance(evidence, dict):
        return ['Missing renewal evidence']
    before, after = (evidence.get(stage) for stage in ('before', 'after'))
    if not all(isinstance(row, dict) for row in (before, after)):
        return ['Renewal requires before and after observations']
    errors = []
    for key, pattern in [('bundle_id', r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+'),
                         ('team_id', r'[A-Z0-9]{10}'), ('marker_sha256', r'[a-f0-9]{64}')]:
        value = before.get(key)
        if not isinstance(value, str) or not re.fullmatch(pattern, value) or value != after.get(key):
            errors.append(f'Renewal: missing, malformed or changed {key}')
    try:
        old, new = (datetime.strptime(row.get('profile_expires_utc'), '%Y-%m-%dT%H:%M:%SZ')
                    for row in (before, after))
        if new <= old:
            errors.append('Renewal: installed profile expiry did not advance')
    except (ValueError, TypeError):
        errors.append('Renewal: both profile expiry times must be UTC timestamps')
    return errors


def validate(report, commit, digest, architecture='standalone', require_renewal=False):
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
    if require_renewal or 'renewal' in report:
        errors.extend(renewal_errors(report.get('renewal')))
    cases = report.get('checks', {})
    if not isinstance(cases, dict):
        return errors + ['checks must be an object']
    if report.get('native_handoff') not in (None, True):
        errors.append('native_handoff must be true or absent')
    if report.get('computer_free_bootstrap') not in (None, True):
        errors.append('computer_free_bootstrap must be true or absent')
    if report.get('apple_account_lifecycle') not in (None, True):
        errors.append('apple_account_lifecycle must be true or absent')
    if report.get('paired_installation') not in (None, True):
        errors.append('paired_installation must be true or absent')
    required = required_cases(architecture)
    if report.get('native_handoff') is True:
        required += NATIVE_HANDOFF_CASES
    elif any(case in cases for case in NATIVE_HANDOFF_CASES):
        # A partially recorded ladder reads like a partial pass. Either the run
        # exercised the native handoff or it did not.
        errors.append('native handoff checks recorded without native_handoff: true')
    if report.get('computer_free_bootstrap') is True:
        required += BOOTSTRAP_CASES
        errors.extend(bootstrap_evidence_errors(report.get('bootstrap')))
    elif any(case in cases for case in BOOTSTRAP_CASES) or 'bootstrap' in report:
        errors.append('bootstrap checks recorded without computer_free_bootstrap: true')
    if report.get('apple_account_lifecycle') is True:
        if report.get('native_handoff') is not True:
            errors.append('apple_account_lifecycle requires native_handoff: true')
        required += APPLE_ACCOUNT_LIFECYCLE_CASES
        errors.extend(apple_account_evidence_errors(report.get('apple_account'), report))
    elif any(case in cases for case in APPLE_ACCOUNT_LIFECYCLE_CASES) or 'apple_account' in report:
        errors.append('apple account checks recorded without apple_account_lifecycle: true')
    if report.get('paired_installation') is True:
        required += PAIRED_INSTALLATION_CASES
        errors.extend(paired_installation_evidence_errors(report.get('paired_installation_evidence'), report))
    elif any(case in cases for case in PAIRED_INSTALLATION_CASES) or 'paired_installation' in report:
        errors.append('paired installation checks recorded without paired_installation: true')
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
    parser.add_argument('--include-computer-free-bootstrap', action='store_true',
                        help='init: also record on-device bootstrap acceptance for this exact IPA')
    parser.add_argument('--include-apple-account-lifecycle', action='store_true',
                        help='init: also record the full Apple Account lifecycle ladder')
    parser.add_argument('--include-paired-installation', action='store_true',
                        help='init: also record the paired installation acceptance ladder')
    parser.add_argument('--renewal', action='store_true',
                        help='Include (init) or require (check) in-place renewal observations')
    args = parser.parse_args()
    init_only = [name for name, enabled in (
        ('--include-native-handoff', args.include_native_handoff),
        ('--include-computer-free-bootstrap', args.include_computer_free_bootstrap),
        ('--include-apple-account-lifecycle', args.include_apple_account_lifecycle),
        ('--include-paired-installation', args.include_paired_installation),
    ) if enabled]
    if args.mode == 'check' and init_only:
        parser.exit(1, f'{init_only[0]} applies to init only; a report declares itself\n')

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
        if args.include_computer_free_bootstrap:
            cases += BOOTSTRAP_CASES
        if args.include_apple_account_lifecycle:
            cases += APPLE_ACCOUNT_LIFECYCLE_CASES
        if args.include_paired_installation:
            cases += PAIRED_INSTALLATION_CASES
        report = dict(architecture=architecture, commit=commit, ipa_sha256=digest, tester='', device_model='',
                      os_version='', tested_at_utc='', checks={
                          case: dict(result='pending', notes='') for case in cases})
        if args.include_native_handoff:
            report['native_handoff'] = True
        if args.include_computer_free_bootstrap:
            report['computer_free_bootstrap'] = True
            report['bootstrap'] = {key: '' for key in BOOTSTRAP_EVIDENCE}
        if args.include_apple_account_lifecycle:
            report['apple_account_lifecycle'] = True
            report['apple_account'] = {key: '' for key in APPLE_ACCOUNT_EVIDENCE}
        if args.include_paired_installation:
            report['paired_installation'] = True
            report['paired_installation_evidence'] = {key: '' for key in PAIRED_INSTALLATION_EVIDENCE}
        if args.renewal:
            report['renewal'] = renewal_template()
        with args.report.open('x') as handle:
            json.dump(report, handle, indent=2)
            handle.write('\n')
        print('Pending report created. No device checks have passed.'
              + (' Native handoff ladder included.' if args.include_native_handoff else '')
              + (' On-device bootstrap cases included.' if args.include_computer_free_bootstrap else '')
              + (' Apple Account lifecycle ladder included.' if args.include_apple_account_lifecycle else '')
              + (' Paired installation ladder included.' if args.include_paired_installation else ''))
        return
    errors = validate(json.loads(args.report.read_text()), commit, digest, architecture, args.renewal)
    if errors:
        parser.exit(1, '\n'.join(errors) + '\n')
    print('Human acceptance report complete for this commit/artifact. This is an attestation, not independent device verification.')


if __name__ == '__main__':
    main()
