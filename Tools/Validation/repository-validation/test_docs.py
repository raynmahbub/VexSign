#!/usr/bin/env python3
"""Regression tests for the offline documentation checker."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('check_docs', Path(__file__).with_name('check-docs.py'))
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


class DocumentationTests(unittest.TestCase):
    def test_links(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'Documentation').mkdir(parents=True)
            (root / 'Documentation/space name.md').write_text('ok')
            (root / 'README.md').write_text(
                '[ok](Documentation/space%20name.md#heading)\n'
                '[remote](https://example.com/no.md)\n[anchor](#heading)\n'
                '```md\n[example](missing-example.md)\n```\n'
                '[missing](Documentation/missing.md)\n![image](missing.png)\n'
                '[escape](../outside.md)\n')
            errors = list(checker.broken_links(root))
            self.assertEqual(len(errors), 3)
            for target in ('Documentation/missing.md', 'missing.png', '../outside.md'):
                self.assertTrue(any(target in error for error in errors))

    def test_paths_named_in_tooling_are_resolved(self):
        """
        A release-note template that names a moved file ships a 404 in every
        release body, and nothing else in the suite looks at those strings.
        """
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'Documentation/Development').mkdir(parents=True)
            (root / 'Documentation/Development/PLATFORMS.md').write_text('ok')
            (root / '.github/workflows').mkdir(parents=True)
            (root / '.github/workflows/release.yml').write_text(
                'see Documentation/Development/PLATFORMS.md\n'
                'see Documentation/Engineering/PLATFORMS.md\n'
                'note: Tools/Validation/security-validation/evidence/run.json\n')
            errors = list(checker.broken_references(root))
            self.assertEqual(len(errors), 1, errors)
            self.assertIn('Documentation/Engineering/PLATFORMS.md', errors[0])
            self.assertIn('release.yml', errors[0])

    def test_test_modules_are_not_scanned_for_references(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'Tools').mkdir(parents=True)
            (root / 'Tools/test_fixture.py').write_text(
                'FIXTURE = "Documentation/missing.md"\n')
            self.assertEqual(list(checker.broken_references(root)), [])

    def test_repository_references(self):
        self.assertEqual(list(checker.broken_references(checker.ROOT)), [])

    def test_download_buttons_and_ci_instructions(self):
        import xml.etree.ElementTree as ET
        readme = (checker.ROOT / 'README.md').read_text()
        self.assertIn('## Download', readme)
        for name in ('download-ipa.svg', 'add-source.svg'):
            self.assertIn('Resources/brand/' + name, readme)
            ET.parse(checker.ROOT / 'VexSign/Resources/brand' / name)
        self.assertIn('https://github.com/raynmahbub/VexSign/releases/latest', readme)
        self.assertIn('VexSign-unsigned-', readme)
        self.assertIn('14 days', readme)
        self.assertIn('applies to new uploads', readme)  # Older runs do not retroactively gain artifacts.

    def test_repository(self):
        self.assertEqual(list(checker.broken_links(checker.ROOT)), [])


if __name__ == '__main__':
    unittest.main(verbosity=2)
