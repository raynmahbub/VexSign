#!/usr/bin/env python3
"""Regression tests for canonical root assets, published aliases and mirrors."""
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

ALL_PAIRS = module.ALIASES + module.MIRRORED


class RepositoryAliasTests(unittest.TestCase):
    def test_alias_table_is_stable_and_canonical_first(self):
        self.assertEqual(module.ALIASES, (
            ("VexSign/Resources/Templates/app-repo.json", "app-repo.json"),
        ))
        for canonical, alias in module.ALIASES:
            self.assertIn("/", canonical)
            self.assertNotIn("/", alias)

    def test_mirrored_resolution_files_are_the_two_xcode_entry_points(self):
        self.assertEqual(len(module.MIRRORED), 1)
        for canonical, alias in module.MIRRORED:
            self.assertTrue(canonical.startswith("VexSign.xcodeproj/"), canonical)
            self.assertTrue(alias.startswith("VexSign.xcworkspace/"), alias)
            self.assertTrue(canonical.endswith("Package.resolved"), canonical)
            self.assertTrue(alias.endswith("Package.resolved"), alias)

    def test_repository_aliases_are_byte_identical(self):
        self.assertEqual(module.problems(), [])

    def _temporary_root(self, directory: str) -> Path:
        root = Path(directory)
        for canonical, alias in ALL_PAIRS:
            c, a = root / canonical, root / alias
            c.parent.mkdir(parents=True, exist_ok=True)
            c.write_bytes(b"canonical")
            a.parent.mkdir(parents=True, exist_ok=True)
            a.write_bytes(b"")
        return root

    def test_sync_repairs_an_empty_alias(self):
        original_root = module.ROOT
        try:
            with tempfile.TemporaryDirectory() as directory:
                module.ROOT = self._temporary_root(directory)
                # One finding per damaged file, aliases and mirrors alike.
                self.assertEqual(len(module.problems()), len(ALL_PAIRS))
                module.sync()
                self.assertEqual(module.problems(), [])
        finally:
            module.ROOT = original_root

    def test_mirror_drift_is_reported_not_ignored(self):
        """The two Xcode entry points resolve independently; drift must fail."""
        original_root = module.ROOT
        try:
            with tempfile.TemporaryDirectory() as directory:
                module.ROOT = self._temporary_root(directory)
                module.sync()
                canonical, alias = module.MIRRORED[0]
                (module.ROOT / alias).write_bytes(b"a different pin")
                found = module.problems()
                self.assertEqual(len(found), 1)
                self.assertIn(alias, found[0])
                self.assertIn(canonical, found[0])
        finally:
            module.ROOT = original_root

    def test_newer_nonempty_workspace_mirror_propagates_to_project(self):
        import os
        original_root = module.ROOT
        try:
            with tempfile.TemporaryDirectory() as directory:
                module.ROOT = self._temporary_root(directory)
                module.sync()
                canonical, alias = module.MIRRORED[0]
                first, second = module.ROOT / canonical, module.ROOT / alias
                second.write_bytes(b"newer workspace pin")
                newer_ns = first.stat().st_mtime_ns + 1_000_000_000
                os.utime(second, ns=(newer_ns, newer_ns))
                module.sync()
                self.assertEqual(first.read_bytes(), b"newer workspace pin")
                self.assertEqual(module.problems(), [])
        finally:
            module.ROOT = original_root


if __name__ == "__main__":
    unittest.main(verbosity=2)
