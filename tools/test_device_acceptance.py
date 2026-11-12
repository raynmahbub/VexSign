#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import unittest
import plistlib
import tempfile
import zipfile
import json
import subprocess
import sys

spec = importlib.util.spec_from_file_location('acceptance', Path(__file__).with_name('device-acceptance.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class AcceptanceTests(unittest.TestCase):
    def report(self):
        return dict(commit='a' * 40, ipa_sha256='b' * 64, tester='Tester',
                    device_model='Test iPhone', os_version='26',
                    tested_at_utc='2026-11-06T10:00:00Z', checks={
                        case: dict(result='pass', notes='Observed on test device')
                        for case in module.CASES})

    def test_complete(self):
        self.assertEqual(module.validate(self.report(), 'a' * 40, 'b' * 64), [])

    def test_wrong_artifact_or_commit(self):
        self.assertEqual(len(module.validate(self.report(), 'c' * 40, 'd' * 64)), 2)

    def test_missing_pending_failed_or_unobserved_checks(self):
        for value in (None, dict(result='pending', notes=''),
                      dict(result='fail', notes='Failed'), dict(result='pass', notes='')):
            report = self.report()
            report['checks']['launch'] = value
            self.assertTrue(module.validate(report, 'a' * 40, 'b' * 64))

    def test_native_report_requires_architecture_specific_observations(self):
        report = self.report()
        self.assertTrue(module.validate(report, 'a' * 40, 'b' * 64, 'native-primary'))
        report['architecture'] = 'native-primary'
        self.assertTrue(module.validate(report, 'a' * 40, 'b' * 64, 'native-primary'))
        for case in module.NATIVE_PRIMARY_CASES:
            report['checks'][case] = dict(result='pending', notes='')
        self.assertTrue(module.validate(report, 'a' * 40, 'b' * 64, 'native-primary'))
        for case in module.NATIVE_PRIMARY_CASES:
            report['checks'][case] = dict(result='pass', notes='Synthetic validator fixture, not device evidence')
        self.assertEqual(module.validate(report, 'a' * 40, 'b' * 64, 'native-primary'), [])
        self.assertTrue(module.validate(report, 'a' * 40, 'b' * 64, 'standalone'))

    def test_architecture_is_classified_from_root_artifact_metadata(self):
        for architecture, flags in [('standalone', {}), ('guest-prototype', {'VexSignCombinedHost': True}),
                                    ('native-primary', {'VexSignCombinedHost': True, 'VexSignPrimaryHost': True})]:
            with tempfile.TemporaryDirectory() as temporary:
                ipa = Path(temporary) / 'fixture.ipa'
                with zipfile.ZipFile(ipa, 'w') as archive:
                    archive.writestr('Payload/Fixture.app/Info.plist', plistlib.dumps(flags))
                    archive.writestr('Payload/Fixture.app/PlugIns/Widget.appex/Info.plist', plistlib.dumps({}))
                self.assertEqual(module.artifact_architecture(ipa), architecture)

    def test_guest_or_inconsistent_primary_cannot_claim_host_acceptance(self):
        for flags in [{'VexSignEmbeddedGuest': True}, {'VexSignPrimaryHost': True},
                      {'VexSignCombinedHost': True, 'VexSignPrimaryHost': True, 'VexSignEmbeddedGuest': True}]:
            with tempfile.TemporaryDirectory() as temporary:
                ipa = Path(temporary) / 'fixture.ipa'
                with zipfile.ZipFile(ipa, 'w') as archive:
                    archive.writestr('Payload/Fixture.app/Info.plist', plistlib.dumps(flags))
                with self.assertRaises(ValueError):
                    module.artifact_architecture(ipa)

    def test_cli_native_report_starts_pending_and_cannot_be_overwritten(self):
        with tempfile.TemporaryDirectory() as temporary:
            ipa = Path(temporary) / 'fixture.ipa'
            report_path = Path(temporary) / 'report.json'
            with zipfile.ZipFile(ipa, 'w') as archive:
                archive.writestr('Payload/Fixture.app/Info.plist', plistlib.dumps({
                    'VexSignCombinedHost': True, 'VexSignPrimaryHost': True}))
            command = [sys.executable, str(Path(module.__file__)), 'init', '--ipa', str(ipa), '--report', str(report_path)]
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads(report_path.read_text())
            self.assertEqual(report['architecture'], 'native-primary')
            self.assertEqual(set(report['checks']), set(module.CASES + module.NATIVE_PRIMARY_CASES))
            self.assertTrue(all(value == {'result': 'pending', 'notes': ''} for value in report['checks'].values()))
            self.assertTrue(module.validate(report, report['commit'], report['ipa_sha256'], 'native-primary'))
            original = report_path.read_bytes()
            again = subprocess.run(command, capture_output=True, text=True)
            self.assertNotEqual(again.returncode, 0)
            self.assertEqual(report_path.read_bytes(), original)

    def test_missing_metadata(self):
        report = self.report()
        report['tester'] = ''
        report['tested_at_utc'] = 'not a timestamp'
        self.assertTrue(module.validate(report, 'a' * 40, 'b' * 64))


class NativeHandoffReportTests(unittest.TestCase):
    """The Free Apple ID ladder is opt-in, but never partial.

    `tools/native-promotion-evidence.py` requires these cases before
    `nativeAppleAccountSigning` may claim `.implemented`, so a report that
    records some of them silently — or declares the ladder and leaves a case
    pending — must fail here rather than look like a pass.
    """

    def report(self):
        report = dict(commit='a' * 40, ipa_sha256='b' * 64, tester='Tester',
                      device_model='Test iPhone', os_version='26',
                      tested_at_utc='2026-11-10T10:00:00Z', native_handoff=True,
                      checks={case: dict(result='pass', notes='Observed on the test device')
                              for case in module.CASES + module.NATIVE_HANDOFF_CASES})
        return report

    def test_declared_ladder_is_complete(self):
        self.assertEqual(module.validate(self.report(), 'a' * 40, 'b' * 64), [])

    def test_declared_ladder_cannot_drop_or_pend_a_case(self):
        report = self.report()
        del report['checks']['native_seven_day_expiry_observed']
        self.assertTrue(module.validate(report, 'a' * 40, 'b' * 64))
        for value in (dict(result='pending', notes=''), dict(result='fail', notes='Install failed'),
                      dict(result='pass', notes='')):
            report = self.report()
            report['checks']['native_install_and_relaunch'] = value
            self.assertTrue(module.validate(report, 'a' * 40, 'b' * 64))

    def test_undeclared_partial_ladder_is_rejected(self):
        report = self.report()
        del report['native_handoff']
        errors = module.validate(report, 'a' * 40, 'b' * 64)
        self.assertTrue(any('without native_handoff: true' in error for error in errors), errors)

    def test_declaration_must_be_boolean(self):
        report = self.report()
        report['native_handoff'] = 'yes'
        errors = module.validate(report, 'a' * 40, 'b' * 64)
        self.assertTrue(any('native_handoff must be true or absent' in error for error in errors), errors)

    def test_ladder_applies_to_every_architecture(self):
        for architecture in ('standalone', 'guest-prototype'):
            report = self.report()
            report['architecture'] = architecture
            self.assertEqual(module.validate(report, 'a' * 40, 'b' * 64, architecture), [])
        report = self.report()
        report['architecture'] = 'native-primary'
        self.assertTrue(module.validate(report, 'a' * 40, 'b' * 64, 'native-primary'))

    def test_cli_creates_the_ladder_only_when_asked(self):
        with tempfile.TemporaryDirectory() as temporary:
            ipa = Path(temporary) / 'fixture.ipa'
            with zipfile.ZipFile(ipa, 'w') as archive:
                archive.writestr('Payload/Fixture.app/Info.plist', plistlib.dumps({}))
            plain = Path(temporary) / 'plain.json'
            ladder = Path(temporary) / 'ladder.json'
            command = [sys.executable, str(Path(module.__file__)), 'init', '--ipa', str(ipa)]
            subprocess.run(command + ['--report', str(plain)], check=True, capture_output=True)
            result = subprocess.run(command + ['--report', str(ladder), '--include-native-handoff'],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('Native handoff ladder included.', result.stdout)
            without = json.loads(plain.read_text())
            with_ladder = json.loads(ladder.read_text())
            self.assertNotIn('native_handoff', without)
            self.assertEqual(set(without['checks']), set(module.CASES))
            self.assertIs(with_ladder['native_handoff'], True)
            self.assertEqual(set(with_ladder['checks']), set(module.CASES + module.NATIVE_HANDOFF_CASES))
            self.assertTrue(all(value == {'result': 'pending', 'notes': ''}
                                for value in with_ladder['checks'].values()))
            self.assertTrue(module.validate(with_ladder, with_ladder['commit'], with_ladder['ipa_sha256']))
            check = subprocess.run([sys.executable, str(Path(module.__file__)), 'check', '--ipa', str(ipa),
                                    '--report', str(ladder), '--include-native-handoff'],
                                   capture_output=True, text=True)
            self.assertNotEqual(check.returncode, 0)
            self.assertIn('applies to init only', check.stderr)


class PendingAcceptanceClaimsTests(unittest.TestCase):
    """Keep published claims behind the device evidence that supports them.

    Two combined-host paths (`native_owned_sign_install`,
    `scoped_unattended_renewal`) cannot be exercised by hosted CI and are still
    unobserved. While DEVICE_TESTING.md says so, the README must keep calling
    native provisioning experimental. This is a consistency guard, not evidence:
    completing the runs is a human step, and removing the caveat should require
    updating the acceptance guide in the same change.
    """

    PENDING_CASES = ('native_owned_sign_install', 'scoped_unattended_renewal')

    def setUp(self):
        self.root = Path(__file__).resolve().parents[1]
        self.guide = (self.root / 'docs/DEVICE_TESTING.md').read_text()
        self.readme = (self.root / 'README.md').read_text()

    def test_pending_paths_are_real_acceptance_cases(self):
        for case in self.PENDING_CASES:
            self.assertIn(case, module.CASES + module.NATIVE_PRIMARY_CASES)
            self.assertIn(case, self.guide)

    def test_guide_still_marks_the_final_paths_pending(self):
        self.assertIn('The final two paths are still incomplete', self.guide)
        self.assertIn('pending', self.guide)
        self.assertIn('cannot perform these physical-device checks', self.guide)

    def test_readme_keeps_the_experimental_caveat_while_paths_are_pending(self):
        if 'The final two paths are still incomplete' not in self.guide:
            self.skipTest('acceptance guide no longer marks the paths pending')
        self.assertIn('Native Apple ID provisioning and guest-host', self.readme)
        self.assertIn('experimental', self.readme)
        self.assertIn('not a complete, device-validated Apple ID signer', self.readme)

    def test_pending_observations_cannot_validate_as_acceptance(self):
        report = dict(commit='a' * 40, ipa_sha256='b' * 64, tester='Tester',
                      device_model='Test iPhone', os_version='26',
                      tested_at_utc='2026-11-06T10:00:00Z', checks={
                          case: dict(result='pass', notes='Observed on test device')
                          for case in module.CASES + module.NATIVE_PRIMARY_CASES})
        report['architecture'] = 'native-primary'
        for case in self.PENDING_CASES:
            report['checks'][case] = dict(result='pending', notes='Not yet exercised')
        self.assertTrue(module.validate(report, 'a' * 40, 'b' * 64))


if __name__ == '__main__':
    unittest.main(verbosity=2)
