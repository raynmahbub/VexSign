#!/usr/bin/env python3
"""Record and check the evidence that may promote Free Apple ID signing.

`SigningMethodCapabilities.nativeAppleAccountSigning` is `.notIntegrated` even
though the handoff code exists, because two things have never been observed:

  * a **genuine Apple-issued** provisioning profile CMS reaching the pinned
    production roots through `NativeAppleProfileCMSVerifier`, and
  * the physical-device ladder in docs/NATIVE_SIGNING_HANDOFF.md (sign in →
    team → register → profile → export → import → sign → verify → install →
    relaunch → seven-day expiry → identity persistence).

Everything the repository can run itself — portable checks, `swift test`,
simulator suites, link smoke, combined builds — passes without either. So the
flip is gated on a recorded artifact instead of on a code edit: this tool writes
a pending record, and `check` refuses to call it complete until genuine CMS
observations, real production wiring and a complete device report are attached.

Rules worth knowing before filling one in:

  * digests and observations only. Raw profile bytes, PKCS#12 material,
    passwords, private keys and device logs never belong in Git (`.gitignore`
    already blocks the usual extensions); a blob-like value is rejected here.
  * the recorded CMS digest must not be one of the committed OpenSSL fixtures.
    Those prove parser behaviour and are explicitly not trust evidence.
  * notes must describe what was observed on Apple hardware, so wording that
    admits synthetic input ("fixture", "simulator", "self-signed") fails.
  * the production factory must actually select `.appleCMS()`. A record cannot
    claim promotion while `SideSignAccountBridge` still defaults to an
    unconfigured validator.

A complete record is a human attestation bound to a commit and artifact digest.
It is not independent verification, and it does not make signing supported on
any device other than the one recorded.

Usage
-----
    python3 tools/native-promotion-evidence.py init  --report docs/evidence/native-signing-promotion.json
    python3 tools/native-promotion-evidence.py check --report docs/evidence/native-signing-promotion.json
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_REPORT = ROOT / 'docs' / 'evidence' / 'native-signing-promotion.json'
# A redacted copy that can actually be committed: `device-acceptance.local.json`
# is gitignored by design, and promotion evidence is reviewed in the repository.
DEVICE_REPORT_HINT = 'docs/evidence/device-acceptance-native-handoff.json'

SCHEMA = 1
CAPABILITY = 'nativeAppleAccountSigning'
PROFILE_SOURCES = ('apple_developer_portal_download',)
CMS_VERIFIERS = ('Security.framework_chain_and_SecKeyVerifySignature',)

# Anything that would smuggle signing material or a payload into the record.
FORBIDDEN_KEYS = frozenset({
    'profile_bytes', 'profile_base64', 'cms_bytes', 'cms_base64', 'cms', 'payload',
    'payload_bytes', 'payload_base64', 'p12', 'pkcs12', 'pkcs12_base64',
    'private_key', 'private_key_base64', 'password', 'certificate_bytes',
    'device_log', 'device_logs', 'udid',
})
# Wording that admits the observation was not made on Apple hardware.
FORBIDDEN_MARKERS = ('synthetic', 'fixture', 'openssl', 'self-signed', 'self signed',
                     'simulator', 'simulated', 'placeholder', 'not evidence',
                     'not observed', 'assumed', 'expected to pass')
MAX_TEXT = 1024

TIMESTAMP = re.compile(r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ')
HEX64 = re.compile(r'[0-9a-f]{64}')
HEX40 = re.compile(r'[0-9a-f]{40}')
UUID_TEXT = re.compile(r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
                       r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')


def acceptance_module():
    """`device-acceptance.py` owns the report vocabulary; do not duplicate it."""
    path = Path(__file__).with_name('device-acceptance.py')
    spec = importlib.util.spec_from_file_location('device_acceptance_for_promotion', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def native_handoff_cases():
    return acceptance_module().NATIVE_HANDOFF_CASES


def current_commit(root: Path = ROOT) -> str:
    try:
        return subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True,
                                       cwd=root, stderr=subprocess.DEVNULL).strip()
    except (subprocess.CalledProcessError, OSError):
        return ''


def is_ancestor(commit: str, root: Path = ROOT) -> bool:
    """True when the tested revision is reachable from the checkout."""
    if not commit:
        return False
    try:
        return subprocess.call(['git', 'merge-base', '--is-ancestor', commit, 'HEAD'],
                               cwd=root, stderr=subprocess.DEVNULL) == 0
    except OSError:
        return False


def is_ignored(relative: str, root: Path = ROOT) -> bool:
    """True when the repository keeps that path out of Git.

    Promotion evidence is reviewed from the repository, so a report referenced by
    a record must be committable. Private working copies (raw logs, portal
    screenshots, device identifiers) stay local; a redacted report goes in.
    """
    if not relative or not current_commit(root):
        return False  # no Git checkout to ask (scratch roots in tests)
    try:
        return subprocess.call(['git', 'check-ignore', '--quiet', relative],
                               cwd=root, stderr=subprocess.DEVNULL) == 0
    except OSError:
        return False


def fixture_digests(root: Path = ROOT) -> set[str]:
    """Digests of committed synthetic material, so it cannot be re-labelled."""
    digests: set[str] = set()
    directory = root / 'NativeSigning' / 'Fixtures'
    if not directory.is_dir():
        return digests
    for path in sorted(directory.rglob('*')):
        if not path.is_file() or path.suffix == '.py':
            continue
        with path.open('rb') as handle:
            digests.add(hashlib.file_digest(handle, 'sha256').hexdigest())
        if path.suffix == '.json':
            try:
                metadata = json.loads(path.read_text())
            except (OSError, json.JSONDecodeError):
                continue
            if isinstance(metadata, dict):
                digests.update(value for value in metadata.values()
                               if isinstance(value, str) and HEX64.fullmatch(value))
    return digests


def production_selects_apple_cms(root: Path = ROOT) -> bool:
    """The shipping bridge must construct a verifier-backed validator."""
    bridge = root / 'NativeSigning' / 'Authentication' / 'SideSignAccountBridge.swift'
    if not bridge.is_file():
        return False
    text = bridge.read_text()
    return bool(re.search(r'profileValidator:\s*NativeProvisioningProfileValidator\s*=\s*\.appleCMS\(\)',
                          text))


def capability_claim(root: Path = ROOT) -> str:
    path = root / 'VexSign' / 'Backend' / 'Services' / 'SigningMethodCapabilities.swift'
    if not path.is_file():
        return 'missing'
    claim = re.search(r'nativeAppleAccountSigning:\s*\.(\w+)', path.read_text())
    return claim.group(1) if claim else 'missing'


def pending_record(commit: str) -> dict:
    """A record that has observed nothing; `check` rejects it."""
    cases = {case: dict(result='pending', notes='') for case in native_handoff_cases()}
    return {
        'schema': SCHEMA,
        'capability': CAPABILITY,
        'commit': commit,
        'status': 'pending',
        'apple_cms': {
            'profile_uuid': '',
            'team_id': '',
            'bundle_id': '',
            'profile_cms_sha256': '',
            'profile_payload_sha256': '',
            'profile_source': '',
            'verifier': '',
            'apple_root_certificates_observed': [],
            'verified_at_utc': '',
            'expiry_observed_utc': '',
            'verified_by': '',
            'verified_on': '',
            'synthetic_or_openssl_input_used': None,
            'notes': '',
        },
        'production_wiring': {
            'factory_selects_apple_cms': False,
            'notes': '',
        },
        'device_acceptance': {
            'report_path': DEVICE_REPORT_HINT,
            'report_sha256': '',
            'ipa_sha256': '',
            'notes': '',
        },
        'handoff_checks': cases,
    }


def _text(value, minimum=1) -> str:
    return value.strip() if isinstance(value, str) and len(value.strip()) >= minimum else ''


def _observation(value) -> str:
    """Non-empty prose that does not admit synthetic input."""
    text = _text(value, 40)
    if not text:
        return ''
    lowered = text.lower()
    if any(marker in lowered for marker in FORBIDDEN_MARKERS):
        return ''
    return text


def _timestamp(value) -> datetime | None:
    if not isinstance(value, str) or not TIMESTAMP.fullmatch(value.strip()):
        return None
    try:
        return datetime.strptime(value.strip(), '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def _forbidden_keys(node, trail='') -> list[str]:
    found = []
    if isinstance(node, dict):
        for key, value in node.items():
            path = f'{trail}.{key}' if trail else str(key)
            if isinstance(key, str) and key.lower() in FORBIDDEN_KEYS:
                found.append(path)
            found.extend(_forbidden_keys(value, path))
    elif isinstance(node, list):
        for index, value in enumerate(node):
            found.extend(_forbidden_keys(value, f'{trail}[{index}]'))
    return found


def _blob_like(node, trail='') -> list[str]:
    found = []
    if isinstance(node, dict):
        for key, value in node.items():
            path = f'{trail}.{key}' if trail else str(key)
            found.extend(_blob_like(value, path))
    elif isinstance(node, list):
        for index, value in enumerate(node):
            found.extend(_blob_like(value, f'{trail}[{index}]'))
    elif isinstance(node, str) and len(node) > MAX_TEXT:
        found.append(trail)
    return found


def validate(record: dict, *, head_commit: str = '', ancestor_of_head=is_ancestor,
             ignored=is_ignored, root: Path = ROOT) -> list[str]:
    """Return every reason this record cannot promote the capability."""
    errors: list[str] = []
    if not isinstance(record, dict):
        return ['Evidence record must be a JSON object']

    if record.get('schema') != SCHEMA:
        errors.append(f'schema must be {SCHEMA}')
    if record.get('capability') != CAPABILITY:
        errors.append(f'capability must be {CAPABILITY}')

    commit = record.get('commit')
    if not isinstance(commit, str) or not HEX40.fullmatch(commit):
        errors.append('commit must be a 40-character lowercase revision')
        commit = ''
    elif head_commit and commit != head_commit and not ancestor_of_head(commit, root):
        errors.append('Evidence commit is neither the checkout nor an ancestor of it; re-run against this source')

    errors.extend(f'forbidden key {path}: record digests, never signing material'
                  for path in _forbidden_keys(record))
    errors.extend(f'{path}: value exceeds {MAX_TEXT} characters; keep blobs out of Git'
                  for path in _blob_like(record))

    errors.extend(_validate_cms(record.get('apple_cms'), root))
    errors.extend(_validate_wiring(record.get('production_wiring'), root))
    errors.extend(_validate_device(record.get('device_acceptance'), record.get('handoff_checks'),
                                   commit, root, ignored))
    return errors


def _validate_cms(cms, root: Path) -> list[str]:
    errors: list[str] = []
    if not isinstance(cms, dict):
        return ['apple_cms: object required']

    if not UUID_TEXT.fullmatch(_text(cms.get('profile_uuid')) or '-'):
        errors.append('apple_cms.profile_uuid: observed Apple profile UUID required')
    team_id = _text(cms.get('team_id'))
    if not re.fullmatch(r'[A-Za-z0-9]{10}', team_id):
        errors.append('apple_cms.team_id: ten-character Apple team identifier required')
    bundle_id = _text(cms.get('bundle_id'))
    if '.' not in bundle_id:
        errors.append('apple_cms.bundle_id: observed application identifier required')

    forbidden = fixture_digests(root)
    digests = {}
    for field in ('profile_cms_sha256', 'profile_payload_sha256'):
        value = cms.get(field)
        if not isinstance(value, str) or not HEX64.fullmatch(value):
            errors.append(f'apple_cms.{field}: 64-character lowercase SHA-256 required')
            continue
        digests[field] = value
        if value in forbidden:
            errors.append(f'apple_cms.{field}: digest matches a committed synthetic fixture, '
                          'which is parser evidence and not Apple trust evidence')
    if len(digests) == 2 and digests['profile_cms_sha256'] == digests['profile_payload_sha256']:
        errors.append('apple_cms: envelope and payload digests must differ')

    if cms.get('profile_source') not in PROFILE_SOURCES:
        errors.append(f'apple_cms.profile_source: must be one of {", ".join(PROFILE_SOURCES)}')
    if cms.get('verifier') not in CMS_VERIFIERS:
        errors.append(f'apple_cms.verifier: must be one of {", ".join(CMS_VERIFIERS)}')

    roots = cms.get('apple_root_certificates_observed')
    if not isinstance(roots, list) or not roots:
        errors.append('apple_cms.apple_root_certificates_observed: list the Apple roots in the observed chain')
    elif not all(isinstance(name, str) and 'Apple' in name for name in roots):
        errors.append('apple_cms.apple_root_certificates_observed: every entry must name an Apple root')

    verified = _timestamp(cms.get('verified_at_utc'))
    if verified is None:
        errors.append('apple_cms.verified_at_utc: YYYY-MM-DDTHH:MM:SSZ required')
    expiry = _timestamp(cms.get('expiry_observed_utc'))
    if expiry is None:
        errors.append('apple_cms.expiry_observed_utc: YYYY-MM-DDTHH:MM:SSZ required')
    if verified and expiry and expiry <= verified:
        errors.append('apple_cms: observed expiry must be after the verification time')

    if not _text(cms.get('verified_by')):
        errors.append('apple_cms.verified_by: name or handle of the person who observed it')
    if not _text(cms.get('verified_on')):
        errors.append('apple_cms.verified_on: macOS/Xcode release used for verification')
    if cms.get('synthetic_or_openssl_input_used') is not False:
        errors.append('apple_cms.synthetic_or_openssl_input_used: must be false for genuine Apple material')
    if not _observation(cms.get('notes')):
        errors.append('apple_cms.notes: at least 40 characters describing the observed Apple chain, '
                      'without synthetic-input wording')
    return errors


def _validate_wiring(wiring, root: Path) -> list[str]:
    errors: list[str] = []
    if not isinstance(wiring, dict):
        return ['production_wiring: object required']
    if wiring.get('factory_selects_apple_cms') is not True:
        errors.append('production_wiring.factory_selects_apple_cms: must be true')
    if not production_selects_apple_cms(root):
        errors.append('production_wiring: SideSignAccountBridge still defaults to an unconfigured '
                      'NativeProvisioningProfileValidator; select .appleCMS() in the production factory')
    if not _text(wiring.get('notes'), 20):
        errors.append('production_wiring.notes: describe the wiring change that ships the verifier')
    return errors


def _validate_device(device, checks, commit: str, root: Path, ignored=is_ignored) -> list[str]:
    errors: list[str] = []
    if not isinstance(device, dict):
        return ['device_acceptance: object required']

    relative = _text(device.get('report_path'))
    if not relative:
        return ['device_acceptance.report_path: repository-relative path to the device report']
    if ignored(relative, root):
        return [f'device_acceptance.report_path: {relative} is gitignored, so it cannot be reviewed; '
                f'commit a redacted copy (for example {DEVICE_REPORT_HINT}) and keep the private '
                f'original local']
    path = (root / relative).resolve()
    if not path.is_relative_to(root.resolve()) or not path.is_file():
        return [f'device_acceptance.report_path: {relative} is not a committed report in this repository']

    try:
        raw = path.read_bytes()
        report = json.loads(raw)
    except (OSError, json.JSONDecodeError) as error:
        return [f'device_acceptance.report_path: unreadable report ({error})']

    digest = hashlib.sha256(raw).hexdigest()
    if device.get('report_sha256') != digest:
        errors.append('device_acceptance.report_sha256: differs from the referenced report')
    if not isinstance(report, dict):
        return errors + ['device_acceptance: report must be a JSON object']

    if report.get('commit') != commit:
        errors.append('device_acceptance: report commit differs from the evidence commit')
    recorded_ipa = device.get('ipa_sha256')
    if not isinstance(recorded_ipa, str) or not HEX64.fullmatch(recorded_ipa):
        errors.append('device_acceptance.ipa_sha256: 64-character lowercase SHA-256 required')
    elif report.get('ipa_sha256') != recorded_ipa:
        errors.append('device_acceptance.ipa_sha256: differs from the tested artifact in the report')

    if report.get('native_handoff') is not True:
        errors.append('device_acceptance: report must be created with --include-native-handoff')
    if not isinstance(checks, dict) or set(checks) != set(native_handoff_cases()):
        errors.append('handoff_checks: must mirror the device report ladder exactly')
    else:
        report_checks = report.get('checks', {})
        for case, expected in checks.items():
            observed = report_checks.get(case) if isinstance(report_checks, dict) else None
            if observed != expected:
                errors.append(f'handoff_checks.{case}: differs from the device report')

    if not _observation(device.get('notes')):
        errors.append('device_acceptance.notes: at least 40 characters describing the device run, '
                      'without synthetic-input wording')

    # The report itself keeps its own vocabulary: architecture, tester, device,
    # timestamp and every required case with an explicit pass and notes.
    acceptance = acceptance_module()
    architecture = report.get('architecture', 'standalone')
    for error in acceptance.validate(report, report.get('commit'), report.get('ipa_sha256'), architecture):
        errors.append(f'device report: {error}')
    return errors


def summarise(record: dict, root: Path = ROOT) -> dict:
    """Facts printed by `check` and reused by tools/check-native-handoff.py."""
    if not isinstance(record, dict):
        record = {}
    cms = record.get('apple_cms') if isinstance(record.get('apple_cms'), dict) else {}
    device = record.get('device_acceptance') if isinstance(record.get('device_acceptance'), dict) else {}
    checks = record.get('handoff_checks') if isinstance(record.get('handoff_checks'), dict) else {}
    passed = sum(1 for case in native_handoff_cases()
                 if isinstance(checks.get(case), dict) and checks[case].get('result') == 'pass')
    return {
        'commit': record.get('commit', ''),
        'apple_cms_recorded': cms.get('synthetic_or_openssl_input_used') is False and bool(cms.get('profile_cms_sha256')),
        'production_verifier': 'yes' if production_selects_apple_cms(root) else 'no',
        'capability': capability_claim(root),
        'device_report': device.get('report_path', ''),
        'handoff_checks_passed': f'{passed}/{len(native_handoff_cases())}',
    }


def load(path: Path):
    try:
        return json.loads(path.read_text()), None
    except FileNotFoundError:
        return None, f'missing evidence record: {path}'
    except (OSError, json.JSONDecodeError) as error:
        return None, f'unreadable evidence record: {error}'


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('mode', choices=('init', 'check'))
    parser.add_argument('--report', type=Path, default=DEFAULT_REPORT)
    parser.add_argument('--root', type=Path, default=ROOT)
    args = parser.parse_args(argv)
    root = args.root.resolve()

    if args.mode == 'init':
        args.report.parent.mkdir(parents=True, exist_ok=True)
        record = pending_record(current_commit(root))
        try:
            with args.report.open('x') as handle:
                json.dump(record, handle, indent=2)
                handle.write('\n')
        except FileExistsError:
            parser.exit(1, f'{args.report} already exists; evidence records are never overwritten\n')
        print('Pending promotion evidence created. Nothing has been verified and the capability '
              'remains .notIntegrated.')
        return 0

    record, problem = load(args.report)
    if problem:
        parser.exit(1, problem + '\n')
    head = current_commit(root)
    errors = validate(record, head_commit=head, root=root)
    facts = summarise(record, root)
    print(f'capability claim:        {facts["capability"]}')
    print(f'evidence commit:         {facts["commit"] or "unrecorded"}')
    print(f'genuine Apple CMS:       {"recorded" if facts["apple_cms_recorded"] else "unrecorded"}')
    print(f'production verifier:     {facts["production_verifier"]}')
    print(f'device report:           {facts["device_report"] or "unrecorded"}')
    print(f'handoff ladder passed:   {facts["handoff_checks_passed"]}')
    if errors:
        print('\nNOT PROMOTABLE:')
        for error in errors:
            print(' -', error)
        return 1
    print('\nPromotion evidence complete for this revision. This is a recorded human attestation, '
          'not independent verification of Apple trust or device behaviour.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
