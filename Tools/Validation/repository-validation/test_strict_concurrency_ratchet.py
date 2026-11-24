#!/usr/bin/env python3
"""Regression tests for the strict-concurrency ratchet (no Xcode, no Swift toolchain).

The `concurrency` job has always been a report: it prints compiler diagnostics and passes. The
ratchet is what turns it into a gate for the code this repository owns, while leaving vendored
checkouts — which nobody here can fix — outside the count. These tests pin the split, the trend and
the "unrecorded baseline is not a failure" rule.
"""

from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location(
    "strict_concurrency_ratchet", ROOT / ".github/scripts/strict_concurrency_ratchet.py")
ratchet = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ratchet)

FIRST_PARTY = "/work/Packages/NimbleKit/Sources/NimbleExtensions/String.swift:12:9: warning: 'nonisolated' is redundant"
THIRD_PARTY = "/work/Packages/Vendor/Nuke/Sources/Task.swift:88:1: warning: sendability of function types"
APP = "/work/VexSign/Storage/Database/Storage.swift:40:5: error: main actor-isolated property"
NOISE = "Compiling VexSign\nwarning: unable to find package manifest"


class SplitTests(unittest.TestCase):
    def test_first_party_diagnostics_are_counted_and_vendored_ones_are_not(self):
        found = ratchet.collect("\n".join([FIRST_PARTY, THIRD_PARTY, APP, NOISE]), ROOT)
        self.assertEqual(len(found), 2)
        self.assertEqual([entry["file"] for entry in found], [
            "Packages/NimbleKit/Sources/NimbleExtensions/String.swift",
            "VexSign/Storage/Database/Storage.swift",
        ])
        self.assertEqual(found[1]["kind"], "error")

    def test_a_log_without_diagnostics_is_empty_not_an_error(self):
        self.assertEqual(ratchet.collect(NOISE, ROOT), [])


class BaselineTests(unittest.TestCase):
    def test_an_unrecorded_baseline_reports_and_passes(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "run.log"
            log.write_text(FIRST_PARTY + "\n")
            baseline = Path(directory) / "baseline.json"
            with mock.patch.object(ratchet.sys, "argv", [
                "ratchet", "--log", str(log), "--baseline", str(baseline), "--root", str(ROOT)]):
                self.assertEqual(ratchet.main(), 0)

    def test_growth_fails_and_shrinking_passes(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "run.log"
            log.write_text("\n".join([FIRST_PARTY, APP]))
            baseline = Path(directory) / "baseline.json"
            baseline.write_text(json.dumps({"count": 1}))
            argv = ["ratchet", "--log", str(log), "--baseline", str(baseline), "--root", str(ROOT)]
            with mock.patch.object(ratchet.sys, "argv", argv):
                self.assertEqual(ratchet.main(), 1)
            baseline.write_text(json.dumps({"count": 5}))
            with mock.patch.object(ratchet.sys, "argv", argv):
                self.assertEqual(ratchet.main(), 0)

    def test_recording_writes_the_measured_count(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "run.log"
            log.write_text("\n".join([FIRST_PARTY, APP, THIRD_PARTY]))
            baseline = Path(directory) / "baseline.json"
            with mock.patch.object(ratchet.sys, "argv", [
                "ratchet", "--log", str(log), "--baseline", str(baseline), "--root", str(ROOT), "--update"]):
                self.assertEqual(ratchet.main(), 0)
            self.assertEqual(ratchet.load_baseline(baseline), 2)

    def test_a_null_or_broken_baseline_counts_as_unrecorded(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "baseline.json"
            path.write_text(json.dumps({"count": None}))
            self.assertIsNone(ratchet.load_baseline(path))
            path.write_text("{ nope")
            self.assertIsNone(ratchet.load_baseline(path))


class SummaryTests(unittest.TestCase):
    def test_the_summary_states_the_delta_and_the_worst_files(self):
        diagnostics = ratchet.collect("\n".join([FIRST_PARTY, APP]), ROOT)
        summary = ratchet.render_summary(diagnostics, baseline=1)
        self.assertIn("Baseline: **1**", summary)
        self.assertIn("+1", summary)
        self.assertIn("Storage.swift", summary)

    def test_an_empty_report_says_so(self):
        self.assertIn("No first-party diagnostics", ratchet.render_summary([], baseline=None))

    def test_pipes_in_a_message_do_not_break_the_table(self):
        diagnostics = [{"file": "A.swift", "line": "1", "kind": "warning", "message": "a | b"}]
        self.assertIn("a \\| b", ratchet.render_summary(diagnostics, baseline=0))


class WiringTests(unittest.TestCase):
    def test_the_job_runs_the_ratchet(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        self.assertIn("strict_concurrency_ratchet.py", workflow)


if __name__ == "__main__":
    unittest.main(verbosity=2)
