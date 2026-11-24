#!/usr/bin/env python3
"""Tests for the Xcode project wiring gate.

The gate exists because a source relocation broke the app's bundle in three ways
at once -- nested synchronized root groups, and resources moved out of the folder
the iOS target synchronizes -- while every other check stayed green. These tests
pin the two failure directions so the gate cannot become decorative:

  * a *new* nesting must fail, and
  * a nesting recorded in the baseline must fail once it is gone, so the
    recorded debt cannot outlive the fix.
"""
import importlib.util
from pathlib import Path
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("check_project_wiring",
                                              HERE / "check_project_wiring.py")
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

PROJECT = """
		AAAA000000000000000000A1 /* App */ = {
			isa = PBXFileSystemSynchronizedRootGroup;
			path = App;
			sourceTree = "<group>";
		};
		AAAA000000000000000000A2 /* App/TV */ = {
			isa = PBXFileSystemSynchronizedRootGroup;
			path = App/TV;
			sourceTree = "<group>";
		};
		AAAA000000000000000000A3 /* Tests */ = {
			isa = PBXFileSystemSynchronizedRootGroup;
			path = Tests;
			sourceTree = "<group>";
		};
		AAAA000000000000000000B1 /* VexSign */ = {
			isa = PBXNativeTarget;
			fileSystemSynchronizedGroups = (
				AAAA000000000000000000A1 /* App */,
			);
		};
		AAAA000000000000000000B2 /* VexSignTV */ = {
			isa = PBXNativeTarget;
			fileSystemSynchronizedGroups = (
				AAAA000000000000000000A2 /* App/TV */,
			);
		};
		AAAA000000000000000000B3 /* VexSignTests */ = {
			isa = PBXNativeTarget;
			fileSystemSynchronizedGroups = (
				AAAA000000000000000000A3 /* Tests */,
			);
		};
"""


class ProjectWiringTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.project = self.root / "project.pbxproj"
        self.project.write_text(PROJECT, encoding="utf-8")
        for relative, _ in gate.BUNDLED_RESOURCES:
            target = self.root / "App" / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("x", encoding="utf-8")
        # Every scanned source root must exist, or the orphan check reports the
        # fixture instead of the property under test.
        for name in gate.SOURCE_ROOTS:
            (self.root / name).mkdir(parents=True, exist_ok=True)

    def tearDown(self):
        self.temporary.cleanup()

    def test_nested_roots_are_reported(self):
        found = gate.problems(root=self.root, project=self.project)
        self.assertTrue(any("nested synchronized roots" in f for f in found), found)
        # The message has to name the symptom, because that is all CI reports.
        joined = "\n".join(found)
        self.assertIn("Unable to find module dependency", joined)
        self.assertIn("PrivacyInfo.xcprivacy", joined)

    def test_un_nesting_is_accepted(self):
        """The shape the fix ships: a sibling folder, still one root per target."""
        self.project.write_text(PROJECT.replace("path = App/TV;", "path = Platform/TV;"),
                                encoding="utf-8")
        (self.root / "Platform" / "TV").mkdir(parents=True, exist_ok=True)
        self.assertEqual(gate.problems(root=self.root, project=self.project), [])

    def test_resource_outside_the_sync_root_is_reported(self):
        (self.root / "App/Resources/ellekit.deb").unlink()
        found = gate.problems(root=self.root, project=self.project)
        self.assertTrue(any("ellekit.deb" in f and "sync root" in f for f in found), found)

    def test_a_root_no_target_synchronizes_is_reported(self):
        """Dead wiring: a root that compiles nothing is silently ignored otherwise."""
        text = PROJECT.replace("\t\t\t\tAAAA000000000000000000A3 /* Tests */,\n", "")
        self.project.write_text(text, encoding="utf-8")
        found = gate.problems(root=self.root, project=self.project)
        self.assertTrue(any("synchronizes no folder" in f for f in found), found)

    def test_a_target_may_synchronize_several_roots(self):
        """The layers are separate roots, so a target legitimately lists more than one."""
        # Tests gains an unrelated sibling root; the fixture's App root stays nested
        # in App/TV, so flatten that first to isolate the property under test.
        text = PROJECT.replace("path = App/TV;", "path = Other/TV;")
        text = text.replace(
            "\t\t\t\tAAAA000000000000000000A3 /* Tests */,\n",
            "\t\t\t\tAAAA000000000000000000A3 /* Tests */,\n"
            "\t\t\t\tAAAA000000000000000000A1 /* App */,\n")
        self.project.write_text(text, encoding="utf-8")
        self.assertEqual(gate.problems(root=self.root, project=self.project), [])

    def test_source_outside_every_root_is_reported(self):
        """A shared layer no root names is never compiled; that is the CI failure."""
        (self.root / "Shared" / "Stranded.swift").write_text("struct S {}", encoding="utf-8")
        found = gate.problems(root=self.root, project=self.project)
        self.assertTrue(any("outside every synchronized root" in f for f in found), found)

    def test_repository_project_is_wired(self):
        self.assertEqual(gate.problems(), [])

    def test_the_repository_project_passes_the_gate_cli(self):
        """The real project runs clean, and says so."""
        import subprocess
        result = subprocess.run(
            [__import__("sys").executable, str(HERE / "check_project_wiring.py")],
            capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("no nesting", result.stdout)

    def test_no_baseline_file_survives(self):
        """Nesting has no tolerance list to hide a regression in."""
        self.assertFalse((HERE / "project-wiring-baseline.json").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
