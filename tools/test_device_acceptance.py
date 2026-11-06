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


if __name__ == '__main__':
    unittest.main(verbosity=2)
