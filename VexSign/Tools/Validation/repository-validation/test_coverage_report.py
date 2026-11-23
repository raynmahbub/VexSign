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

ROOT = Path(__file__).resolve().parents[4]
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
            file_report("/runner/work/project/VexSign/App/iOS/Infrastructure/Persistence/Database/Storage.swift", 5, 50),
            file_report("/runner/work/project/VexSign/App/iOS/Infrastructure/Diagnostics/FileLogger.swift", 25, 30),
            file_report("/runner/work/project/VexSign/App/iOS/Domain/Empty.swift", 0, 0),
            file_report("/runner/DerivedData/SourcePackages/checkouts/Nuke/Sources/Task.swift", 0, 400),
            file_report("/runner/work/project/VexSign/Tests/UnitTests/Application/SomeTests.swift", 0, 200),
        ],
    }],
}


class FilteringTests(unittest.TestCase):
    def test_dependencies_and_test_bundles_are_excluded(self):
        self.assertFalse(coverage.is_first_party("/x/SourcePackages/checkouts/Nuke/Sources/Task.swift"))
        self.assertFalse(coverage.is_first_party("/x/VexSign/Tests/UnitTests/Application/SomeTests.swift"))
        self.assertFalse(coverage.is_first_party("/x/VexSign/App/iOS/Thing.h"))
        self.assertTrue(coverage.is_first_party("/x/VexSign/App/iOS/Infrastructure/Persistence/Database/Storage.swift"))

    def test_summary_uses_totals_and_sorts_worst_first(self):
        percent, covered, executable, files = coverage.summarise(REPORT)
        self.assertEqual(percent, 30.0)
        self.assertEqual((covered, executable), (30, 100))
        # Zero-line files and dependencies are dropped; worst coverage first.
        self.assertEqual([entry["name"] for entry in files],
                         ["Infrastructure/Persistence/Database/Storage.swift", "Infrastructure/Diagnostics/FileLogger.swift"])

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
        self.assertIn("Infrastructure/Persistence/Database/Storage.swift", markdown)
        self.assertIn("10.0%", markdown)


class CommandLineTests(unittest.TestCase):
    def test_missing_bundle_is_a_warning_not_a_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            missing = Path(directory) / "absent.xcresult"
            with mock.patch.object(coverage.sys, "argv", ["coverage_report.py", "--result-bundle", str(missing)]):
                self.assertEqual(coverage.main(), 0)

    def test_xccov_failure_is_visible_but_tolerated(self):
        # The CI step carries `continue-on-error`, so a non-zero exit turns the step
        # orange without failing the build. It used to return 0, which is how the
        # coverage pipeline stayed dead for the whole life of the job.
        with tempfile.TemporaryDirectory() as directory:
            bundle = Path(directory) / "tests.xcresult"
            bundle.mkdir()
            with mock.patch.object(coverage.sys, "argv", ["coverage_report.py", "--result-bundle", str(bundle)]), \
                 mock.patch.object(coverage, "xccov_json",
                                   side_effect=coverage.CoverageUnavailable("no coverage data")):
                self.assertEqual(coverage.main(), 1)

    def test_failure_records_the_reason_in_the_artifact(self):
        with tempfile.TemporaryDirectory() as directory:
            bundle = Path(directory) / "tests.xcresult"
            bundle.mkdir()
            raw = Path(directory) / "coverage.json"
            with mock.patch.object(coverage.sys, "argv",
                                   ["coverage_report.py", "--result-bundle", str(bundle), "--json", str(raw)]), \
                 mock.patch.object(coverage, "xccov_json",
                                   side_effect=coverage.CoverageUnavailable("not a result bundle")):
                self.assertEqual(coverage.main(), 1)
            self.assertEqual(json.loads(raw.read_text()),
                             {"coverageAvailable": False, "error": "not a result bundle"})

    def test_xccov_stderr_reaches_the_annotation(self):
        # The old `check=True` surfaced only the argv, which is why every failing run
        # said "returned non-zero exit status 1" and nothing about why.
        completed = mock.Mock(returncode=1, stdout="", stderr="Error: no coverage data\n")
        with mock.patch.object(coverage.subprocess, "run", return_value=completed):
            with self.assertRaises(coverage.CoverageUnavailable) as raised:
                coverage.xccov_json(Path("/tmp/absent.xcresult"))
        self.assertIn("no coverage data", str(raised.exception))

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


class TrendTests(unittest.TestCase):
    def test_the_report_states_the_floor_and_its_status(self):
        markdown = coverage.render_markdown(*coverage.summarise(REPORT), floor=20.0)
        self.assertIn("Floor: **20.0%** (ok)", markdown)

    def test_without_a_baseline_the_report_says_so_instead_of_printing_a_delta(self):
        markdown = coverage.render_markdown(*coverage.summarise(REPORT))
        self.assertIn("No baseline recorded yet", markdown)
        self.assertNotIn("pt**", markdown)

    def test_a_baseline_produces_a_signed_delta(self):
        below = coverage.render_markdown(*coverage.summarise(REPORT), baseline=34.5)
        self.assertIn("Baseline: **34.5%**", below)
        self.assertIn("-4.5 pt", below)
        above = coverage.render_markdown(*coverage.summarise(REPORT), baseline=25.0)
        self.assertIn("+5.0 pt", above)

    def test_a_null_or_broken_baseline_is_absent_not_zero(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "baseline.json"
            path.write_text(json.dumps({"percent": None}))
            self.assertIsNone(coverage.load_baseline(path))
            path.write_text("{ not json")
            self.assertIsNone(coverage.load_baseline(path))
            self.assertIsNone(coverage.load_baseline(Path(directory) / "absent.json"))
            self.assertIsNone(coverage.load_baseline(None))

    def test_recording_a_baseline_writes_a_rounded_percentage(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "baseline.json"
            coverage.write_baseline(path, 30.04)
            payload = json.loads(path.read_text())
            self.assertEqual(payload["percent"], 30.0)
            self.assertTrue(payload["recordedAt"])
            self.assertEqual(coverage.load_baseline(path), 30.0)

    def test_update_baseline_records_the_measured_number(self):
        with tempfile.TemporaryDirectory() as directory:
            bundle = Path(directory) / "tests.xcresult"
            bundle.mkdir()
            path = Path(directory) / "baseline.json"
            with mock.patch.object(coverage.sys, "argv",
                                   ["coverage_report.py", "--result-bundle", str(bundle),
                                    "--baseline", str(path), "--update-baseline"]), \
                 mock.patch.object(coverage, "xccov_json", return_value=REPORT):
                self.assertEqual(coverage.main(), 0)
            self.assertEqual(coverage.load_baseline(path), 30.0)


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

    def test_ci_enables_coverage_on_the_test_command(self):
        # The scheme sets it too, but the flag on the command line is what survives a
        # scheme edit; without either, xccov has nothing to read.
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        # The tests job is the only place a `test` action runs; the build job's
        # `xcodebuild build` has no coverage to enable.
        tests_job = workflow.split("- name: Run tests", 1)[1].split("- name: Surface failures", 1)[0]
        self.assertIn("-enableCodeCoverage YES", tests_job)



class FloorTests(unittest.TestCase):
    """The floor is a collapse detector, and a missing number is not a floor breach."""

    def test_below_the_floor(self):
        self.assertEqual(coverage.floor_status(12.0, 20.0), "below_floor")

    def test_at_the_floor_still_passes_but_warns(self):
        self.assertEqual(coverage.floor_status(20.0, 20.0), "at_floor")
        self.assertEqual(coverage.floor_status(21.9, 20.0), "at_floor")

    def test_above_the_floor(self):
        self.assertEqual(coverage.floor_status(30.0, 20.0), "ok")

    def test_no_floor_means_no_verdict(self):
        self.assertEqual(coverage.floor_status(1.0, None), "ok")

    def test_github_output_lines(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "output"
            coverage._write_github_output(target, {"percent": "71.5", "floor": "20.0", "floor_status": "ok"})
            self.assertEqual(
                target.read_text(encoding="utf-8"),
                "percent=71.5\nfloor=20.0\nfloor_status=ok\n",
            )

    def test_no_output_file_is_not_an_error(self):
        coverage._write_github_output(None, {"percent": "1"})

if __name__ == "__main__":
    unittest.main()