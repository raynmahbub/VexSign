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
            (root / 'docs').mkdir()
            (root / 'docs/space name.md').write_text('ok')
            (root / 'README.md').write_text(
                '[ok](docs/space%20name.md#heading)\n'
                '[remote](https://example.com/no.md)\n[anchor](#heading)\n'
                '```md\n[example](missing-example.md)\n```\n'
                '[missing](docs/missing.md)\n![image](missing.png)\n'
                '[escape](../outside.md)\n')
            errors = list(checker.broken_links(root))
            self.assertEqual(len(errors), 3)
            for target in ('docs/missing.md', 'missing.png', '../outside.md'):
                self.assertTrue(any(target in error for error in errors))

    def test_repository(self):
        self.assertEqual(list(checker.broken_links(checker.ROOT)), [])


if __name__ == '__main__':
    unittest.main(verbosity=2)
