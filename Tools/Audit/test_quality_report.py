#!/usr/bin/env python3
"""Tests for the CI quality report: a skipped test must never become a pass."""

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("vexsign_quality_report", ROOT / "Tools/Audit/quality-report.py")
quality = importlib.util.module_from_spec(spec)
spec.loader.exec_module(quality)


class QualityReportTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)
        self.results = self.dir / "tests.json"
        self.log = self.dir / "test.log"
        self.log.write_text("Test Suite 'All tests' passed\n", encoding="utf-8")

    def _write_results(self, payload):
        self.results.write_text(json.dumps(payload), encoding="utf-8")
        return self.results

    def test_container_nodes_are_not_counted_as_tests(self):
        path = self._write_results({
            "name": "All tests", "result": "passed",
            "children": [
                {"name": "A_tests", "result": "passed", "children": [
                    {"name": "testA", "result": "passed"},
                    {"name": "testB", "result": "skipped"},
                ]},
            ],
        })
        report = quality.build_report(test_results=path, test_log=self.log)
        self.assertEqual(report["tests"]["counts"], {"failed": 0, "passed": 1, "skipped": 1})
        self.assertEqual(report["tests"]["executed"], 1)
        self.assertEqual(report["status"], "passed")

    def test_failed_leaf_fails_the_report(self):
        path = self._write_results({
            "name": "All tests", "result": "failed",
            "children": [{"name": "testSigning", "result": "failed",
                          "failureMessages": [{"failureMessage": "XCTAssertEqual failed"}]}],
        })
        report = quality.build_report(test_results=path, test_log=self.log)
        self.assertEqual(report["status"], "failed")
        self.assertTrue(any("testSigning" in problem for problem in report["blocked"]))

    def test_no_executed_test_is_not_a_pass(self):
        path = self._write_results({"name": "All tests", "result": "skipped",
                                    "children": [{"name": "testA", "result": "skipped"}]})
        report = quality.build_report(test_results=path, test_log=self.log)
        self.assertEqual(report["status"], "failed")
        self.assertTrue(any("No test executed" in problem for problem in report["blocked"]))
        self.assertIn("- Skipped: 1", quality.markdown(report))

    def test_crash_markers_are_reported(self):
        self.log.write_text("Thread 2 Crashed:\n0 libsystem 0x1 crash\n", encoding="utf-8")
        path = self._write_results({"name": "All tests", "result": "passed",
                                    "children": [{"name": "testA", "result": "passed"}]})
        report = quality.build_report(test_results=path, test_log=self.log)
        self.assertTrue(any("Thread" in signal for signal in report["crash_signals"]))
        # A crash marker is not a cosmetic note: it blocks the report even when
        # the xcresult leaf says passed.
        self.assertEqual(report["status"], "failed")
        self.assertTrue(any("CRASH" in problem for problem in report["blocked"]))

    def test_device_evidence_is_required_when_asked(self):
        path = self._write_results({"name": "All tests", "result": "passed",
                                    "children": [{"name": "testA", "result": "passed"}]})
        report = quality.build_report(test_results=path, test_log=self.log, require_device=True)
        self.assertEqual(report["status"], "failed")
        self.assertEqual(report["device"]["status"], "blocked")
        self.assertTrue(any("Device evidence is required" in problem for problem in report["blocked"]))


if __name__ == "__main__":
    unittest.main()
