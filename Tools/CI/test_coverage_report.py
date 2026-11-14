#!/usr/bin/env python3
"""Regression tests for the CI coverage summariser (no Xcode needed)."""

import importlib.util
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "coverage_report", ROOT / ".github/scripts/coverage_report.py")
coverage = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(coverage)


def file_report(path, covered, executable):
    return {
        "path": path,
        "coveredLines": covered,
        "executableLines": executable,
        "lineCoverage": (covered / executable) if executable else 0.0,
    }


REPORT = {
    "coveredLines": 30,
    "executableLines": 100,
    "lineCoverage": 0.30,
    "targets": [{
        "name": "VexSign.app",
        "files": [
            file_report("/runner/work/App/iOS/VexSign/App/iOS/VexSign/Backend/Storage/Storage.swift", 5, 50),
            file_report("/runner/work/App/iOS/VexSign/App/iOS/VexSign/Utilities/FileLogger.swift", 25, 30),
            file_report("/runner/work/App/iOS/VexSign/App/iOS/VexSign/Empty.swift", 0, 0),
            file_report("/runner/DerivedData/SourcePackages/checkouts/Nuke/Sources/Task.swift", 0, 400),
            file_report("/runner/work/App/iOS/VexSign/App/Tests/VexSignTests/SomeTests.swift", 0, 200),
        ],
    }],
}


class FilteringTests(unittest.TestCase):
    def test_dependencies_and_test_bundles_are_excluded(self):
        self.assertFalse(coverage.is_first_party("/x/SourcePackages/checkouts/Nuke/Sources/Task.swift"))
        self.assertFalse(coverage.is_first_party("/x/App/Tests/VexSignTests/SomeTests.swift"))
        self.assertFalse(coverage.is_first_party("/x/App/iOS/VexSign/Thing.h"))
        self.assertTrue(coverage.is_first_party("/x/App/iOS/VexSign/Backend/Storage/Storage.swift"))

    def test_summary_uses_totals_and_sorts_worst_first(self):
        percent, covered, executable, files = coverage.summarise(REPORT)
        self.assertEqual(percent, 30.0)
        self.assertEqual((covered, executable), (30, 100))
        # Zero-line files and dependencies are dropped; worst coverage first.
        self.assertEqual([entry["name"] for entry in files],
                         ["Backend/Storage/Storage.swift", "Utilities/FileLogger.swift"])

    def test_empty_report_does_not_divide_by_zero(self):
        percent, covered, executable, files = coverage.summarise({})
        self.assertEqual((percent, covered, executable, files), (0.0, 0, 0, []))
        self.assertIn("no first-party coverage data", coverage.render_markdown(percent, covered, executable, files))

    def test_limit_is_respected(self):
        _, _, _, files = coverage.summarise(REPORT, limit=1)
        self.assertEqual(len(files), 1)


class RenderingTests(unittest.TestCase):
    def test_markdown_contains_the_number_and_a_table(self):
        markdown = coverage.render_markdown(*coverage.summarise(REPORT))
        self.assertIn("**30.0%**", markdown)
        self.assertIn("| File | Coverage | Covered / Executable |", markdown)
        self.assertIn("Backend/Storage/Storage.swift", markdown)
        self.assertIn("10.0%", markdown)


class CommandLineTests(unittest.TestCase):
    def test_missing_bundle_is_a_warning_not_a_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            missing = Path(directory) / "absent.xcresult"
            with mock.patch.object(coverage.sys, "argv", ["coverage_report.py", "--result-bundle", str(missing)]):
                self.assertEqual(coverage.main(), 0)

    def test_xccov_failure_does_not_fail_the_job(self):
        with tempfile.TemporaryDirectory() as directory:
            bundle = Path(directory) / "tests.xcresult"
            bundle.mkdir()
            with mock.patch.object(coverage.sys, "argv", ["coverage_report.py", "--result-bundle", str(bundle)]), \
                 mock.patch.object(coverage, "xccov_json", side_effect=subprocess.CalledProcessError(1, "xccov")):
                self.assertEqual(coverage.main(), 0)

    def test_report_is_appended_to_the_job_summary(self):
        with tempfile.TemporaryDirectory() as directory:
            bundle = Path(directory) / "tests.xcresult"
            bundle.mkdir()
            summary = Path(directory) / "summary.md"
            raw = Path(directory) / "coverage.json"
            with mock.patch.object(coverage.sys, "argv",
                                   ["coverage_report.py", "--result-bundle", str(bundle), "--json", str(raw)]), \
                 mock.patch.object(coverage, "xccov_json", return_value=REPORT), \
                 mock.patch.dict(os.environ, {"GITHUB_STEP_SUMMARY": str(summary)}):
                self.assertEqual(coverage.main(), 0)
            self.assertIn("**30.0%**", summary.read_text())
            self.assertEqual(json.loads(raw.read_text())["coveredLines"], 30)


class SchemeTests(unittest.TestCase):
    def test_coverage_is_enabled_in_the_shared_test_scheme(self):
        scheme = (ROOT / "VexSign.xcodeproj/xcshareddata/xcschemes/VexSignTests.xcscheme").read_text()
        self.assertIn('codeCoverageEnabled = "YES"', scheme)
        # It must be on the TestAction, not some other action.
        test_action = scheme.split("<TestAction", 1)[1].split("</TestAction>", 1)[0]
        self.assertIn('codeCoverageEnabled = "YES"', test_action)

    def test_ci_reports_coverage_after_testing(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        self.assertIn("coverage_report.py", workflow)
        self.assertIn("-resultBundlePath", workflow)


if __name__ == "__main__":
    unittest.main()
