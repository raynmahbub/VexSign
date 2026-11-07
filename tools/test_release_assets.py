#!/usr/bin/env python3
import hashlib
import importlib.util
import json
import os
import shutil
import subprocess
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('assets', Path(__file__).with_name('prepare-release-assets.py'))
assets = importlib.util.module_from_spec(spec)
spec.loader.exec_module(assets)


class ReleaseAssetTests(unittest.TestCase):
    def test_channels_and_checksums(self):
        for channel in ('stable', 'nightly', 'prerelease'):
            with self.subTest(channel=channel), tempfile.TemporaryDirectory() as directory:
                output = Path(directory)
                (output / 'VexSign-1.2.0.ipa').write_bytes(b'test artifact, not a real IPA')
                with patch.object(assets.subprocess, 'check_output', side_effect=['a' * 40, '## Changes\n']):
                    assets.prepare(output, '1.2.0', channel, 'owner/repo')
                metadata = json.loads((output / 'RELEASE.json').read_text())
                self.assertEqual(metadata['channel'], channel)
                self.assertEqual(metadata['ipa']['name'], 'VexSign-1.2.0.ipa')
                self.assertTrue(metadata['unsigned'])
                notes = (output / 'CHANGELOG.md').read_text()
                self.assertIn('not a screenshot', notes)
                self.assertIn('a' * 40, notes)
                for line in (output / 'SHA256SUMS').read_text().splitlines():
                    digest, name = line.split('  ')
                    self.assertEqual(hashlib.sha256((output / name).read_bytes()).hexdigest(), digest)
                self.assertEqual(len((output / 'SHA256SUMS').read_text().splitlines()), 5)

    def test_prerelease_asset_uses_base_app_version_in_filename(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            (output / 'VexSign-1.2.0.ipa').write_bytes(b'pre-release artifact')
            with patch.object(assets.subprocess, 'check_output', side_effect=['a' * 40, '## Changes\\n']):
                assets.prepare(output, '1.2.0-nightly.20261107.1', 'nightly', 'owner/repo')
            metadata = json.loads((output / 'RELEASE.json').read_text())
            self.assertEqual(metadata['ipa']['name'], 'VexSign-1.2.0.ipa')

    def test_reviewed_stable_notes_do_not_republish_obsolete_commit_claims(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            (output / 'VexSign-1.1.0.ipa').write_bytes(b'synthetic artifact')
            with patch.object(assets.subprocess, 'check_output', side_effect=[
                    'a' * 40, 'feat: obsolete claim of complete native signing and unattended renewal']):
                assets.prepare(output, '1.1.0', 'stable', 'owner/repo')
            notes = (output / 'CHANGELOG.md').read_text()
            self.assertNotIn('obsolete claim', notes)
            self.assertIn('Not complete:', notes)
            self.assertIn('default CMS gate remains closed', notes)
            self.assertIn('versioned changelog', notes)
            self.assertEqual(json.loads((output / 'RELEASE.json').read_text())['notes_source'], 'reviewed-version-notes')

    def test_makefile_ipa_filename_contains_app_version(self):
        makefile = (assets.ROOT / 'Makefile').read_text()
        self.assertIn('APP_VERSION ?=', makefile)
        self.assertIn('IPA_FILE := packages/$(NAME)-$(APP_VERSION).ipa', makefile)
        self.assertIn('zip -r9 "$(IPA_FILE)" Payload', makefile)

    def test_misnamed_ipa_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            (output / 'VexSign.ipa').write_bytes(b'legacy filename')
            with self.assertRaisesRegex(ValueError, 'Expected versioned IPA name'):
                assets.prepare(output, '1.2.0', 'stable', 'owner/repo')

    def test_missing_or_ambiguous_ipa(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            for names in ((), ('one.ipa', 'two.ipa')):
                for name in names:
                    (output / name).touch()
                with self.assertRaises(ValueError):
                    assets.prepare(output, '1.2.0', 'stable', 'owner/repo')

    def test_unsafe_metadata(self):
        with self.assertRaises(ValueError):
            assets.prepare(Path('.'), '../../bad', 'stable', 'owner/repo')
        with self.assertRaises(ValueError):
            assets.prepare(Path('.'), '1.2.0', 'stable', '../../bad')


class ChangelogTests(unittest.TestCase):
    def test_stable_skips_nightlies_and_empty_range_has_no_old_commit(self):
        with tempfile.TemporaryDirectory() as directory:
            def git(*args):
                return subprocess.check_output(['git', *args], cwd=directory, text=True)
            git('init', '-q')
            git('config', 'user.name', 'Test')
            git('config', 'user.email', 'test@example.invalid')
            git('commit', '--allow-empty', '-qm', 'feat: initial')
            git('tag', 'v1.0.0')
            git('commit', '--allow-empty', '-qm', 'fix: after stable')
            git('tag', 'v1.1.0-nightly.1')
            git('commit', '--allow-empty', '-qm', 'feat: after nightly')
            git('commit', '--allow-empty', '-qm', 'fix(parser)!: scoped breaking fix')
            git('commit', '--allow-empty', '-qm', '123 unclassified subject')
            # Model BSD sed's rejection of inline branch separators even on
            # Linux; all other work still runs through the real sed binary.
            shim = Path(directory) / 'bin'
            shim.mkdir()
            sed = shim / 'sed'
            sed.write_text('#!/bin/sh\ncase "$*" in *";t;"*) echo "BSD sed: undefined label" >&2; exit 1;; esac\nexec "$REAL_SED" "$@"\n')
            sed.chmod(0o755)
            script = str(assets.ROOT / 'tools/generate-changelog.sh')
            def notes(version, **extra):
                return subprocess.check_output(['bash', script], cwd=directory, text=True,
                    env={**os.environ, 'VERSION': version, 'REAL_SED': shutil.which('sed'),
                         'PATH': str(shim) + os.pathsep + os.environ['PATH'], **extra})
            stable = notes('1.1.0')
            self.assertIn('VexSign-1.1.0.ipa', stable)
            self.assertIn('after stable', stable)
            self.assertIn('after nightly', stable)
            self.assertNotIn('- initial', stable)
            self.assertIn('- scoped breaking fix', stable)
            self.assertIn('### Other changes', stable)
            self.assertIn('- 123 unclassified subject', stable)
            empty = notes('1.1.0-nightly.2', BASE_SHA=git('rev-parse', 'HEAD').strip())
            self.assertIn('VexSign-1.1.0.ipa', empty)
            self.assertIn('No source changes', empty)
            self.assertNotIn('- after nightly', empty)


if __name__ == '__main__':
    unittest.main(verbosity=2)
