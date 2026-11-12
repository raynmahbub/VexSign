#!/usr/bin/env python3
"""Regressions for the Free Apple ID promotion evidence gate.

The point of these tests is the direction that must keep failing: a capability
flip with no genuine Apple CMS observation and no physical-device ladder. They
build scratch checkouts from the real sources, so a change to the production
bridge default, the caveat copy or the handoff doc is what the gate sees.

Nothing here is evidence. Every digest, timestamp and observation below is
invented for the validator, and `tools/native-promotion-evidence.py` says so.
"""
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


promotion = load('promotion_evidence_under_test', 'native-promotion-evidence.py')
gate = load('native_handoff_gate_under_test', 'check-native-handoff.py')
acceptance = load('device_acceptance_under_test', 'device-acceptance.py')

BRIDGE = Path('NativeSigning/Authentication/SideSignAccountBridge.swift')
FIXTURES = (Path('NativeSigning/Fixtures/cms_v1_sha256_rsa.der'),
            Path('NativeSigning/Fixtures/cms_v1_sha256_rsa.json'))
COPIED = (gate.CAPABILITIES, gate.MANAGER, gate.FLOW, gate.BACKEND, gate.HANDOFF_DOC, BRIDGE) + FIXTURES
REPORT_RELATIVE = 'device-acceptance.local.json'
COMMIT = 'a' * 40
OTHER_COMMIT = 'c' * 40
IPA = 'b' * 64


class PromotionEvidenceTestCase(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        for relative in COPIED:
            target = self.root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(REPO / relative, target)
        self.select_production_verifier()
        self.record = self.complete_record()

    # -- scratch checkout helpers ------------------------------------------ #

    def select_production_verifier(self, configured=True):
        """Mirror (or undo) the production wiring change promotion requires."""
        path = self.root / BRIDGE
        text = path.read_text()
        replacement = '.appleCMS()' if configured else '.init()'
        path.write_text(text.replace('profileValidator: NativeProvisioningProfileValidator = .init()',
                                     f'profileValidator: NativeProvisioningProfileValidator = {replacement}')
                        .replace('profileValidator: NativeProvisioningProfileValidator = .appleCMS()',
                                 f'profileValidator: NativeProvisioningProfileValidator = {replacement}'))

    def write_report(self, report=None, relative=REPORT_RELATIVE):
        report = self.device_report() if report is None else report
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(report, indent=2) + '\n')
        return path

    def device_report(self, commit=COMMIT, ipa=IPA, native_handoff=True,
                      handoff_result='pass', handoff_notes='Observed during the native handoff device run'):
        checks = {case: dict(result='pass', notes='Observed on the dedicated test iPhone')
                  for case in acceptance.CASES}
        for case in acceptance.NATIVE_HANDOFF_CASES:
            checks[case] = dict(result=handoff_result, notes=handoff_notes)
        report = dict(architecture='standalone', commit=commit, ipa_sha256=ipa, tester='Test maintainer',
                      device_model='Test iPhone', os_version='26.1', tested_at_utc='2026-11-10T09:00:00Z',
                      checks=checks)
        if native_handoff:
            report['native_handoff'] = True
        return report

    def complete_record(self):
        report_path = self.write_report()
        return dict(
            schema=promotion.SCHEMA,
            capability=promotion.CAPABILITY,
            commit=COMMIT,
            status='complete',
            apple_cms=dict(
                profile_uuid='0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0',
                team_id='ABCDE12345',
                bundle_id='com.example.handoff',
                profile_cms_sha256='c' * 64,
                profile_payload_sha256='d' * 64,
                profile_source='apple_developer_portal_download',
                verifier='Security.framework_chain_and_SecKeyVerifySignature',
                apple_root_certificates_observed=['Apple Root CA',
                                                  'Apple Worldwide Developer Relations Certification Authority'],
                verified_at_utc='2026-11-10T08:00:00Z',
                expiry_observed_utc='2026-11-17T08:00:00Z',
                verified_by='Test maintainer',
                verified_on='macOS 26.1 with Xcode 26.2',
                synthetic_or_openssl_input_used=False,
                notes='Apple development profile downloaded from the developer portal and chained to '
                      'Apple roots on the test Mac.'),
            production_wiring=dict(
                factory_selects_apple_cms=True,
                notes='SideSignAccountBridge now constructs the verifier-backed validator.'),
            device_acceptance=dict(
                report_path=REPORT_RELATIVE,
                report_sha256=hashlib.sha256(report_path.read_bytes()).hexdigest(),
                ipa_sha256=IPA,
                notes='Dedicated test iPhone run covering sign, verify, install, relaunch and expiry.'),
            handoff_checks={case: dict(result='pass', notes='Observed during the native handoff device run')
                            for case in acceptance.NATIVE_HANDOFF_CASES})

    def check(self, record=None, head_commit=COMMIT, ancestor=None, ignored=None):
        record = self.record if record is None else record
        return promotion.validate(record, head_commit=head_commit,
                                  ancestor_of_head=ancestor or (lambda commit, root: False),
                                  ignored=ignored or (lambda relative, root: False),
                                  root=self.root)

    def assertRejected(self, record, fragment):
        errors = self.check(record)
        self.assertTrue(any(fragment in error for error in errors), errors)

    # -- the positive direction -------------------------------------------- #

    def test_complete_genuine_record_promotes(self):
        self.assertEqual(self.check(), [])
        facts = promotion.summarise(self.record, self.root)
        self.assertEqual(facts['production_verifier'], 'yes')
        self.assertEqual(facts['handoff_checks_passed'], f'{len(acceptance.NATIVE_HANDOFF_CASES)}/'
                                                        f'{len(acceptance.NATIVE_HANDOFF_CASES)}')
        self.assertTrue(facts['apple_cms_recorded'])

    def test_evidence_commit_may_be_an_ancestor_of_the_checkout(self):
        self.assertEqual(self.check(head_commit=OTHER_COMMIT,
                                    ancestor=lambda commit, root: commit == COMMIT), [])
        self.assertRejected({**self.record, 'commit': OTHER_COMMIT}, 'neither the checkout nor an ancestor')

    # -- synthetic material can never be relabelled ------------------------- #

    def test_committed_fixture_digest_is_not_apple_evidence(self):
        fixture = json.loads((self.root / FIXTURES[1]).read_text())
        for field, digest in (('profile_cms_sha256', fixture['cms_sha256']),
                              ('profile_payload_sha256', fixture['payload_sha256'])):
            record = json.loads(json.dumps(self.record))
            record['apple_cms'][field] = digest
            self.assertRejected(record, 'committed synthetic fixture')

    def test_recorded_cms_and_payload_digests_must_differ(self):
        record = json.loads(json.dumps(self.record))
        record['apple_cms']['profile_payload_sha256'] = record['apple_cms']['profile_cms_sha256']
        self.assertRejected(record, 'must differ')

    def test_synthetic_attestation_and_wording_are_rejected(self):
        for value in (True, None, 'false'):
            record = json.loads(json.dumps(self.record))
            record['apple_cms']['synthetic_or_openssl_input_used'] = value
            self.assertRejected(record, 'synthetic_or_openssl_input_used')
        for notes in ('OpenSSL fixture used for the chain.', 'Verified in the simulator.',
                      'Self-signed certificate chained fine.', 'Short.'):
            record = json.loads(json.dumps(self.record))
            record['apple_cms']['notes'] = notes
            self.assertRejected(record, 'apple_cms.notes')

    def test_apple_chain_facts_are_required(self):
        mutations = (
            (('profile_source', 'openssl_generated'), 'profile_source'),
            (('verifier', 'NativeProfileCMSEnvelope.parse'), 'verifier'),
            (('apple_root_certificates_observed', []), 'apple_root_certificates_observed'),
            (('apple_root_certificates_observed', ['Let\'s Encrypt R11']), 'name an Apple root'),
            (('profile_uuid', 'not-a-uuid'), 'profile_uuid'),
            (('team_id', 'SHORT'), 'team_id'),
            (('bundle_id', 'nodot'), 'bundle_id'),
            (('profile_cms_sha256', 'nope'), 'profile_cms_sha256'),
            (('verified_at_utc', '2026-11-10 08:00'), 'verified_at_utc'),
            (('expiry_observed_utc', '2026-11-01T08:00:00Z'), 'after the verification time'),
            (('verified_by', ''), 'verified_by'),
            (('verified_on', ''), 'verified_on'),
        )
        for (field, value), fragment in mutations:
            record = json.loads(json.dumps(self.record))
            record['apple_cms'][field] = value
            self.assertRejected(record, fragment)

    def test_signing_material_and_blobs_cannot_be_recorded(self):
        for key in ('cms_base64', 'private_key', 'password', 'udid'):
            record = json.loads(json.dumps(self.record))
            record['apple_cms'][key] = 'recorded anyway'
            self.assertRejected(record, f'forbidden key apple_cms.{key}')
        record = json.loads(json.dumps(self.record))
        record['apple_cms']['notes'] = 'x' * (promotion.MAX_TEXT + 1)
        self.assertRejected(record, 'keep blobs out of Git')

    def test_schema_and_capability_must_match(self):
        for field, value, fragment in (('schema', 2, 'schema must be'),
                                       ('capability', 'vexSignPrimaryHost', 'capability must be'),
                                       ('commit', 'short', '40-character lowercase revision')):
            record = json.loads(json.dumps(self.record))
            record[field] = value
            self.assertRejected(record, fragment)

    # -- production wiring is part of the claim ---------------------------- #

    def test_record_cannot_promote_an_unconfigured_production_validator(self):
        self.select_production_verifier(configured=False)
        errors = self.check()
        self.assertTrue(any('unconfigured' in error for error in errors), errors)
        self.assertEqual(promotion.summarise(self.record, self.root)['production_verifier'], 'no')

    def test_wiring_notes_are_required(self):
        record = json.loads(json.dumps(self.record))
        record['production_wiring'] = dict(factory_selects_apple_cms=True, notes='')
        self.assertRejected(record, 'production_wiring.notes')
        record['production_wiring'] = dict(factory_selects_apple_cms=False,
                                           notes='Verifier wired in the production factory.')
        self.assertRejected(record, 'factory_selects_apple_cms')

    # -- the device ladder must be complete -------------------------------- #

    def test_missing_or_partial_device_ladder_is_rejected(self):
        for case in acceptance.NATIVE_HANDOFF_CASES:
            for result, notes in (('pending', ''), ('fail', 'Install did not complete'), ('pass', '')):
                report = self.device_report(handoff_result=result, handoff_notes=notes)
                report['checks'][case] = dict(result=result, notes=notes)
                path = self.write_report(report)
                record = json.loads(json.dumps(self.record))
                record['handoff_checks'][case] = dict(result=result, notes=notes)
                record['device_acceptance']['report_sha256'] = (
                    hashlib.sha256(path.read_bytes()).hexdigest())
                self.assertTrue(self.check(record), f'{case} {result}')

    def test_report_must_declare_the_native_handoff(self):
        report = self.device_report(native_handoff=False)
        path = self.write_report(report)
        record = json.loads(json.dumps(self.record))
        record['device_acceptance']['report_sha256'] = hashlib.sha256(path.read_bytes()).hexdigest()
        errors = self.check(record)
        self.assertTrue(any('--include-native-handoff' in error for error in errors), errors)

    def test_report_binding_is_checked(self):
        mutations = (
            (lambda report: report.update(commit=OTHER_COMMIT), 'report commit differs'),
            (lambda report: report.update(ipa_sha256='e' * 64), 'ipa_sha256'),
            (lambda report: report.update(tester=''), 'Missing tester'),
            (lambda report: report['checks'].update(launch=dict(result='pending', notes='')), 'launch'),
        )
        for mutate, fragment in mutations:
            report = self.device_report()
            mutate(report)
            path = self.write_report(report)
            record = json.loads(json.dumps(self.record))
            record['device_acceptance']['report_sha256'] = (
                hashlib.sha256(path.read_bytes()).hexdigest())
            self.assertRejected(record, fragment)

    def test_gitignored_report_cannot_back_promotion(self):
        # The private working copy exists on disk and matches by digest, but it
        # can never be reviewed from the repository.
        errors = self.check(ignored=lambda relative, root: True)
        self.assertTrue(any('gitignored' in error for error in errors), errors)
        self.assertTrue(any(promotion.DEVICE_REPORT_HINT in error for error in errors), errors)

    def test_default_report_path_is_committable_in_this_repository(self):
        self.assertTrue(promotion.is_ignored('device-acceptance.local.json', REPO))
        self.assertFalse(promotion.is_ignored(promotion.DEVICE_REPORT_HINT, REPO))
        self.assertFalse(promotion.is_ignored(gate.EVIDENCE_RELATIVE.as_posix(), REPO))
        self.assertFalse(promotion.is_ignored('', REPO))

    def test_report_digest_and_path_must_match_the_committed_file(self):
        record = json.loads(json.dumps(self.record))
        record['device_acceptance']['report_sha256'] = 'f' * 64
        self.assertRejected(record, 'report_sha256')
        record = json.loads(json.dumps(self.record))
        record['device_acceptance']['report_path'] = 'docs/evidence/absent.json'
        self.assertRejected(record, 'is not a committed report')
        record = json.loads(json.dumps(self.record))
        record['device_acceptance']['report_path'] = '../../etc/passwd'
        self.assertRejected(record, 'is not a committed report')

    def test_recorded_ladder_must_mirror_the_report(self):
        record = json.loads(json.dumps(self.record))
        record['handoff_checks']['native_install_and_relaunch'] = dict(result='pass', notes='Rewritten later')
        self.assertRejected(record, 'handoff_checks.native_install_and_relaunch')
        record = json.loads(json.dumps(self.record))
        del record['handoff_checks']['native_seven_day_expiry_observed']
        self.assertRejected(record, 'handoff_checks: must mirror')
        record = json.loads(json.dumps(self.record))
        record['device_acceptance']['notes'] = 'Synthetic device run, not evidence.'
        self.assertRejected(record, 'device_acceptance.notes')

    # -- CLI behaviour ------------------------------------------------------ #

    def test_pending_record_is_created_once_and_never_passes(self):
        path = self.root / 'docs/evidence/native-signing-promotion.json'
        command = [sys.executable, str(REPO / 'tools/native-promotion-evidence.py'), 'init',
                   '--report', str(path), '--root', str(self.root)]
        self.assertEqual(subprocess.run(command, capture_output=True, text=True).returncode, 0)
        pending = json.loads(path.read_text())
        self.assertEqual(pending['commit'], promotion.current_commit(self.root))
        self.assertTrue(all(value['result'] == 'pending' for value in pending['handoff_checks'].values()))
        self.assertTrue(self.check(pending, head_commit=''))
        original = path.read_bytes()
        again = subprocess.run(command, capture_output=True, text=True)
        self.assertNotEqual(again.returncode, 0)
        self.assertEqual(path.read_bytes(), original)

    def test_check_cli_reports_every_blocker(self):
        path = self.root / 'docs/evidence/native-signing-promotion.json'
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(self.record, indent=2) + '\n')
        self.select_production_verifier(configured=False)
        result = subprocess.run([sys.executable, str(REPO / 'tools/native-promotion-evidence.py'), 'check',
                                 '--report', str(path), '--root', str(self.root)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn('NOT PROMOTABLE', result.stdout)
        self.assertIn('unconfigured', result.stdout)
        self.select_production_verifier()
        result = subprocess.run([sys.executable, str(REPO / 'tools/native-promotion-evidence.py'), 'check',
                                 '--report', str(path), '--root', str(self.root)],
                                capture_output=True, text=True)
        # The scratch checkout has no Git history, so `current_commit` is empty
        # and the revision binding is skipped; everything else is complete.
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn('handoff ladder passed:   8/8', result.stdout)
        self.assertIn('Promotion evidence complete', result.stdout)
        self.assertIn('not independent verification', result.stdout)


class CapabilityGateTests(PromotionEvidenceTestCase):
    """The gate couples the flag, the caveat, the doc and the evidence."""

    def evidence_path(self):
        return self.root / gate.EVIDENCE_RELATIVE

    def write_evidence(self, record=None):
        path = self.evidence_path()
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(self.record if record is None else record, indent=2) + '\n')
        return path

    def claim(self, integrated):
        path = self.root / gate.CAPABILITIES
        replacement = '.implemented' if integrated else '.notIntegrated'
        path.write_text(path.read_text().replace('nativeAppleAccountSigning: .notIntegrated',
                                                 f'nativeAppleAccountSigning: {replacement}')
                        .replace('nativeAppleAccountSigning: .implemented',
                                 f'nativeAppleAccountSigning: {replacement}'))

    def retire_documented_gap(self):
        """What a promotion change must also do: caveat copy and doc status."""
        flow = self.root / gate.FLOW
        flow.write_text(flow.read_text().replace('Native signing handoff is not enabled',
                                                 'Native signing handoff'))
        doc = self.root / gate.HANDOFF_DOC
        text = doc.read_text()
        doc.write_text(text.replace('Production gate still closed', 'Production gate open')
                       .replace('remains\n`.notIntegrated`', 'is now `.implemented`'))

    def test_repository_state_is_consistent(self):
        problems, facts = gate.evaluate(REPO)
        self.assertEqual(problems, [])
        self.assertEqual(facts['claim'], 'notIntegrated')
        self.assertEqual(facts['promotion evidence'], 'absent')
        self.assertEqual(facts['production CMS verifier'], 'no')
        self.assertEqual(facts['app adapter present'], 'yes')
        self.assertEqual(facts['profile export present'], 'yes')

    def test_scratch_checkout_starts_consistent(self):
        problems, facts = gate.evaluate(self.root)
        self.assertEqual(problems, [])
        self.assertEqual(facts['production CMS verifier'], 'yes')

    def test_flip_without_evidence_is_rejected(self):
        self.claim(integrated=True)
        problems, facts = gate.evaluate(self.root)
        self.assertEqual(facts['promotion evidence'], 'absent')
        self.assertTrue(any('promotion evidence' in problem and 'absent' in problem for problem in problems),
                        problems)
        self.assertTrue(any('production CMS gate as closed' in problem for problem in problems), problems)
        self.assertTrue(any('not enabled' in problem for problem in problems), problems)

    def test_flip_without_production_verifier_is_rejected(self):
        self.select_production_verifier(configured=False)
        self.claim(integrated=True)
        self.retire_documented_gap()
        self.write_evidence()
        problems, facts = gate.evaluate(self.root)
        self.assertEqual(facts['production CMS verifier'], 'no')
        self.assertTrue(any('unconfigured NativeProvisioningProfileValidator' in problem for problem in problems),
                        problems)

    def test_incomplete_evidence_does_not_promote(self):
        self.claim(integrated=True)
        self.retire_documented_gap()
        record = json.loads(json.dumps(self.record))
        record['apple_cms']['synthetic_or_openssl_input_used'] = True
        self.write_evidence(record)
        problems, facts = gate.evaluate(self.root)
        self.assertEqual(facts['promotion evidence'], 'incomplete')
        self.assertTrue(any('is incomplete' in problem for problem in problems), problems)
        self.assertTrue(any('evidence: ' in problem for problem in problems), problems)

    def test_unreadable_evidence_is_invalid_not_absent(self):
        self.claim(integrated=True)
        self.retire_documented_gap()
        path = self.evidence_path()
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('{not json')
        problems, facts = gate.evaluate(self.root)
        self.assertEqual(facts['promotion evidence'], 'invalid')
        self.assertTrue(any('is invalid' in problem for problem in problems), problems)

    def test_complete_evidence_and_retired_caveat_promote(self):
        self.claim(integrated=True)
        self.retire_documented_gap()
        self.write_evidence()
        problems, facts = gate.evaluate(self.root)
        self.assertEqual(facts, {'claim': 'implemented', 'app adapter present': 'yes',
                                 'profile export present': 'yes', 'UI explains the gap': 'no',
                                 'production CMS verifier': 'yes', 'promotion evidence': 'complete'})
        self.assertEqual(problems, [])

    def test_complete_evidence_while_not_integrated_is_a_stale_claim(self):
        self.write_evidence()
        problems, facts = gate.evaluate(self.root)
        self.assertEqual(facts['promotion evidence'], 'complete')
        self.assertTrue(any('still .notIntegrated' in problem for problem in problems), problems)

    def test_gate_cli_reports_the_real_checkout(self):
        result = subprocess.run([sys.executable, str(REPO / 'tools/check-native-handoff.py')],
                                capture_output=True, text=True, cwd=REPO)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('nativeAppleAccountSigning: notIntegrated', result.stdout)
        self.assertIn('production CMS verifier:   no', result.stdout)
        self.assertIn('promotion evidence:        absent', result.stdout)


if __name__ == '__main__':
    unittest.main(verbosity=2)
