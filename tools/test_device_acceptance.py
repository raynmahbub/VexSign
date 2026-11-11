#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import unittest
import os
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
            # Bind to a commit explicitly so this test does not depend on cwd having .git.
            command += ['--commit', 'f' * 40]
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads(report_path.read_text())
            self.assertEqual(report['architecture'], 'native-primary')
            self.assertEqual(report['commit'], 'f' * 40)
            self.assertEqual(set(report['checks']), set(module.CASES + module.NATIVE_PRIMARY_CASES))
            self.assertTrue(all(value == {'result': 'pending', 'notes': ''} for value in report['checks'].values()))
            self.assertTrue(module.validate(report, report['commit'], report['ipa_sha256'], 'native-primary'))
            original = report_path.read_bytes()
            again = subprocess.run(command, capture_output=True, text=True)
            self.assertNotEqual(again.returncode, 0)
            self.assertEqual(report_path.read_bytes(), original)

    # MARK: - Source archive vs git checkout

    def test_a_source_archive_without_git_metadata_still_initialises_a_report(self):
        """`make verify` runs from an unpacked zip, which has no `.git`.

        The utility used to call `git rev-parse HEAD` unconditionally, so this exact case
        ended in `fatal: not a git repository` and the acceptance suite failed for a reason
        that had nothing to do with device acceptance. The fix must keep binding the report
        to a commit, not skip the check.
        """
        with tempfile.TemporaryDirectory() as temporary:
            archive_root = Path(temporary)
            (archive_root / 'Payload').mkdir()
            ipa = archive_root / 'fixture.ipa'
            with zipfile.ZipFile(ipa, 'w') as archive:
                archive.writestr('Payload/Fixture.app/Info.plist', plistlib.dumps({}))
            report_path = archive_root / 'report.json'

            # `cwd` inside the archive root: there is no .git here, which is the whole point.
            # A PATH without git makes the absence deterministic even on a host that has one.
            environment = {key: value for key, value in os.environ.items() if key != 'GITHUB_SHA'}
            environment.pop('VEXSIGN_SOURCE_COMMIT', None)
            environment['PATH'] = ''
            result = subprocess.run(
                [sys.executable, str(Path(module.__file__)), 'init', '--ipa', str(ipa),
                 '--report', str(report_path), '--commit', 'a' * 40],
                capture_output=True, text=True, cwd=archive_root, env=environment)
            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads(report_path.read_text())
            self.assertEqual(report['commit'], 'a' * 40)
            # Pending and unobserved: the report exists, but every field still has to be
            # filled in by a human before `check` will accept it.
            errors = module.validate(report, 'a' * 40, report['ipa_sha256'])
            for key in ('tester', 'device_model', 'os_version', 'tested_at_utc'):
                self.assertIn(f'Missing {key}', errors)
            for case in module.CASES:
                self.assertIn(f'{case}: requires explicit pass and observation notes', errors)

    def test_ci_environment_commit_is_used_when_git_is_absent(self):
        with tempfile.TemporaryDirectory() as temporary:
            ipa = Path(temporary) / 'fixture.ipa'
            report_path = Path(temporary) / 'report.json'
            with zipfile.ZipFile(ipa, 'w') as archive:
                archive.writestr('Payload/Fixture.app/Info.plist', plistlib.dumps({}))
            environment = dict(os.environ, VEXSIGN_SOURCE_COMMIT='b' * 40, PATH='')
            environment.pop('GITHUB_SHA', None)
            result = subprocess.run(
                [sys.executable, str(Path(module.__file__)), 'init', '--ipa', str(ipa),
                 '--report', str(report_path)],
                capture_output=True, text=True, cwd=temporary, env=environment)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(report_path.read_text())['commit'], 'b' * 40)

    def test_missing_commit_fails_with_a_diagnostic_not_a_traceback(self):
        with tempfile.TemporaryDirectory() as temporary:
            ipa = Path(temporary) / 'fixture.ipa'
            report_path = Path(temporary) / 'report.json'
            with zipfile.ZipFile(ipa, 'w') as archive:
                archive.writestr('Payload/Fixture.app/Info.plist', plistlib.dumps({}))
            environment = {key: value for key, value in os.environ.items()
                           if key not in ('GITHUB_SHA', 'VEXSIGN_SOURCE_COMMIT')}
            # Descendants inherit the environment plus the overridden PATH. An empty PATH also
            # removes any git the host happens to have, so "no metadata" is guaranteed here.
            environment['PATH'] = str(Path(sys.executable).parent)
            result = subprocess.run(
                [sys.executable, str(Path(module.__file__)), 'init', '--ipa', str(ipa),
                 '--report', str(report_path)],
                capture_output=True, text=True, cwd=temporary, env=environment)
            self.assertEqual(result.returncode, 2)
            self.assertIn('No source commit could be established', result.stderr)
            self.assertIn('--commit', result.stderr)
            self.assertNotIn('Traceback', result.stderr)
            self.assertFalse(report_path.exists(), 'a report must never be written without a commit')

    def test_explicit_commit_wins_over_environment_and_git(self):
        with tempfile.TemporaryDirectory() as temporary:
            ipa = Path(temporary) / 'fixture.ipa'
            report_path = Path(temporary) / 'report.json'
            with zipfile.ZipFile(ipa, 'w') as archive:
                archive.writestr('Payload/Fixture.app/Info.plist', plistlib.dumps({}))
            environment = dict(os.environ, VEXSIGN_SOURCE_COMMIT='c' * 40, GITHUB_SHA='d' * 40, PATH='')
            result = subprocess.run(
                [sys.executable, str(Path(module.__file__)), 'init', '--ipa', str(ipa),
                 '--report', str(report_path), '--commit', 'e' * 40],
                capture_output=True, text=True, cwd=temporary, env=environment)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(report_path.read_text())['commit'], 'e' * 40)

    def test_commit_resolution_rejects_a_placeholder(self):
        for value in ('', '   ', 'HEAD', 'main', 'abc123', 'not-a-sha'):
            with self.subTest(value=value):
                with self.assertRaises(module.CommitUnavailable):
                    module.resolve_commit(value, environ={'PATH': ''})
        self.assertEqual(module.resolve_commit('A' * 40, environ={'PATH': ''}), 'a' * 40)

    def test_check_mode_still_requires_the_report_to_match_the_commit(self):
        """The looser resolution must not weaken the integrity check it feeds."""
        with tempfile.TemporaryDirectory() as temporary:
            ipa = Path(temporary) / 'fixture.ipa'
            report_path = Path(temporary) / 'report.json'
            with zipfile.ZipFile(ipa, 'w') as archive:
                archive.writestr('Payload/Fixture.app/Info.plist', plistlib.dumps({}))
            init = subprocess.run(
                [sys.executable, str(Path(module.__file__)), 'init', '--ipa', str(ipa),
                 '--report', str(report_path), '--commit', 'a' * 40],
                capture_output=True, text=True)
            self.assertEqual(init.returncode, 0, init.stderr)
            checked = subprocess.run(
                [sys.executable, str(Path(module.__file__)), 'check', '--ipa', str(ipa),
                 '--report', str(report_path), '--commit', 'b' * 40],
                capture_output=True, text=True)
            self.assertNotEqual(checked.returncode, 0)
            self.assertIn('Report commit differs from checkout', checked.stderr)

    def test_missing_metadata(self):
        report = self.report()
        report['tester'] = ''
        report['tested_at_utc'] = 'not a timestamp'
        self.assertTrue(module.validate(report, 'a' * 40, 'b' * 64))


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
