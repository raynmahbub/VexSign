#!/usr/bin/env python3
"""Regression tests for canonical root assets and published compatibility aliases."""
from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    "sync_repo_aliases", Path(__file__).with_name("sync_repo_aliases.py"))
module = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(module)


class RepositoryAliasTests(unittest.TestCase):
    def test_alias_table_is_stable_and_canonical_first(self):
        self.assertEqual(len(module.ALIASES), 5)
        for canonical, alias in module.ALIASES:
            self.assertIn("/", canonical)
            self.assertNotIn("/", alias)

    def test_repository_aliases_are_byte_identical(self):
        self.assertEqual(module.problems(), [])

    def test_sync_repairs_an_empty_alias(self):
        original_root = module.ROOT
        try:
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                module.ROOT = root
                for canonical, alias in module.ALIASES:
                    c, a = root / canonical, root / alias
                    c.parent.mkdir(parents=True, exist_ok=True)
                    c.write_bytes(b"canonical")
                    a.parent.mkdir(parents=True, exist_ok=True)
                    a.write_bytes(b"")
                self.assertEqual(len(module.problems()), len(module.ALIASES))
                module.sync()
                self.assertEqual(module.problems(), [])
        finally:
            module.ROOT = original_root


if __name__ == "__main__":
    unittest.main(verbosity=2)
