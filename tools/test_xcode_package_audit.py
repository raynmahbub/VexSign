#!/usr/bin/env python3
"""Offline tests for Xcode package requirement audit semantics."""
import runpy
import unittest
from pathlib import Path

AUDIT = runpy.run_path(str(Path(__file__).with_name("check-xcode-packages.py")))
Requirement = AUDIT["Requirement"]
choose = AUDIT["choose"]
has_update = AUDIT["has_update"]


class AuditTests(unittest.TestCase):
    def requirement(self, kind, version):
        return Requirement("test", "https://github.com/example/test", kind, version, "")

    def test_exact_pin_is_not_compatible_with_a_newer_major(self):
        req = self.requirement("exactVersion", "12.8.0")
        self.assertEqual(choose(req, ["13.2.3", "12.8.0", "12.7.0"]), "12.8.0")
        self.assertIsNone(choose(req, ["13.2.3"]))

    def test_exact_pin_still_reports_newer_candidate_for_review(self):
        req = self.requirement("exactVersion", "12.8.0")
        req.latest = "13.2.3"
        req.compatible = "12.8.0"
        self.assertTrue(has_update(req))
        req.latest = "12.7.0"
        self.assertFalse(has_update(req))

    def test_older_versions_do_not_satisfy_the_minimum(self):
        self.assertIsNone(choose(self.requirement("upToNextMinorVersion", "4.8.6"), ["4.8.5"]))

    def test_ranges_select_only_allowed_major_or_minor(self):
        versions = ["5.0.0", "4.9.1", "4.8.7", "4.8.6"]
        self.assertEqual(choose(self.requirement("upToNextMajorVersion", "4.8.6"), versions), "4.9.1")
        self.assertEqual(choose(self.requirement("upToNextMinorVersion", "4.8.6"), versions), "4.8.7")


if __name__ == "__main__":
    unittest.main()
