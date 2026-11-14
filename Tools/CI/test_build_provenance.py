import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('provenance', ROOT / 'Tools/Release/write-build-provenance.py')
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class BuildProvenanceTests(unittest.TestCase):
    def ipa(self, root, revision):
        ipa = root / 'VexSign-8.0.ipa'
        with zipfile.ZipFile(ipa, 'w') as archive:
            archive.writestr('Payload/VexSign.app/Info.plist', plistlib.dumps(dict(
                VexSignSourceCommit=revision, CFBundleVersion='123', CFBundleShortVersionString='8.0')))
        return ipa

    def test_exact_ipa_source_and_checksum(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            revision = 'a' * 40
            ipa = self.ipa(root, revision)
            result = MODULE.generate(root, revision)
            self.assertEqual(result['source_commit'], revision)
            self.assertEqual(result['artifacts'][0]['sha256'], hashlib.sha256(ipa.read_bytes()).hexdigest())
            for line in (root / 'SHA256SUMS').read_text().splitlines():
                digest, filename = line.split('  ')
                self.assertEqual(hashlib.sha256((root / filename).read_bytes()).hexdigest(), digest)
            self.assertEqual(json.loads((root / 'BUILD.json').read_text())['artifacts'][0]['build'], '123')

    def test_wrong_source_fails_before_writing_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.ipa(root, 'a' * 40)
            with self.assertRaises(ValueError):
                MODULE.generate(root, 'b' * 40)
            self.assertFalse((root / 'BUILD.json').exists())

    def test_missing_ipa_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ValueError):
                MODULE.generate(Path(directory), 'a' * 40)

    def test_artifact_changes_change_checksum(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ipa = self.ipa(root, 'a' * 40)
            first = MODULE.generate(root, 'a' * 40)['artifacts'][0]['sha256']
            with zipfile.ZipFile(ipa, 'a') as archive:
                archive.writestr('Payload/VexSign.app/new-file', b'new bytes')
            self.assertNotEqual(first, MODULE.generate(root, 'a' * 40)['artifacts'][0]['sha256'])


if __name__ == '__main__':
    unittest.main()
