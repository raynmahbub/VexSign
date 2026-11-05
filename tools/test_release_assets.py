#!/usr/bin/env python3
import hashlib
import importlib.util
import json
import os
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
                (output / 'VexSign.ipa').write_bytes(b'test artifact, not a real IPA')
                with patch.object(assets.subprocess, 'check_output', side_effect=['a' * 40, '## Changes\n']):
                    assets.prepare(output, '1.2.0', channel, 'owner/repo')
                metadata = json.loads((output / 'RELEASE.json').read_text())
                self.assertEqual(metadata['channel'], channel)
                self.assertTrue(metadata['unsigned'])
                notes = (output / 'CHANGELOG.md').read_text()
                self.assertIn('not a screenshot', notes)
                self.assertIn('a' * 40, notes)
                for line in (output / 'SHA256SUMS').read_text().splitlines():
                    digest, name = line.split('  ')
                    self.assertEqual(hashlib.sha256((output / name).read_bytes()).hexdigest(), digest)
                self.assertEqual(len((output / 'SHA256SUMS').read_text().splitlines()), 5)

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
            script = str(assets.ROOT / 'tools/generate-changelog.sh')
            def notes(version, **extra):
                return subprocess.check_output(['bash', script], cwd=directory, text=True,
                    env={**os.environ, 'VERSION': version, **extra})
            stable = notes('1.1.0')
            self.assertIn('after stable', stable)
            self.assertIn('after nightly', stable)
            self.assertNotIn('- initial', stable)
            empty = notes('1.1.0-nightly.2', BASE_SHA=git('rev-parse', 'HEAD').strip())
            self.assertIn('No source changes', empty)
            self.assertNotIn('- after nightly', empty)


if __name__ == '__main__':
    unittest.main(verbosity=2)
