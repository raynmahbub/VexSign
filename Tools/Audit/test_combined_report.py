#!/usr/bin/env python3
"""Offline tests for the consolidated evidence report."""

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("vexsign_combined_report", ROOT / "Tools/Audit/combined-report.py")
combined = importlib.util.module_from_spec(spec)
spec.loader.exec_module(combined)


def passed_report():
    return {"status": "passed", "tests": {"counts": {"passed": 2, "failed": 0, "skipped": 0},
                                          "executed": 2}, "crash_signals": [], "blocked": []}


class CombinedReportTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)

    def test_missing_ui_report_is_blocked_not_passed(self):
        (self.dir / "quality-report.json").write_text(json.dumps(passed_report()))
        report, markdown = combined.build(self.dir, {"build": "success", "ui-tests": "failure"})
        self.assertEqual(report["status"], "failed")
        self.assertIn("BLOCKED", markdown)
        self.assertIn("`ui-tests`: failure", markdown)

    def test_only_executed_evidence_can_be_green(self):
        (self.dir / "quality-report.json").write_text(json.dumps(passed_report()))
        (self.dir / "ui-quality-report.json").write_text(json.dumps(passed_report()))
        (self.dir / "ui-test-results.json").write_text(json.dumps(
            {"results": [{"attachments": [{"name": "screenshot"}, {"name": "screenshot"}]}]}))
        report, markdown = combined.build(self.dir, {"build": "success", "tests": "success",
                                                     "ui-tests": "success", "quick": "success"})
        self.assertEqual(report["status"], "passed")
        self.assertIn("Screenshot/attachment records in xcresult JSON: 2", markdown)
        self.assertIn("no device report", markdown)

    def test_skipped_job_and_crash_marker_stay_failed(self):
        broken = passed_report()
        broken["crash_signals"] = ["Thread 2 Crashed"]
        broken["status"] = "failed"
        broken["blocked"] = ["CRASH Thread 2 Crashed"]
        (self.dir / "quality-report.json").write_text(json.dumps(passed_report()))
        (self.dir / "ui-quality-report.json").write_text(json.dumps(broken))
        report, _ = combined.build(self.dir, {"build": "success", "device": "skipped"})
        self.assertEqual(report["status"], "failed")


if __name__ == "__main__":
    unittest.main()
