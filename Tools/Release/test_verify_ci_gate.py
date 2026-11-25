#!/usr/bin/env python3
"""Offline tests for the release CI gate."""

import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("vexsign_verify_ci_gate", ROOT / "Tools/Release/verify_ci_gate.py")
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

SHA = "a" * 40


def run(*names_success, **overrides):
    runs = [{"name": name, "conclusion": "success", "completed_at": "2026-11-24T10:00:00Z"}
            for name in names_success]
    for name, conclusion in overrides.items():
        runs.append({"name": name, "conclusion": conclusion, "completed_at": "2026-11-24T11:00:00Z"})
    return runs


class VerifyCiGateTests(unittest.TestCase):
    def test_all_required_checks_succeed(self):
        errors, statuses = gate.evaluate(run(*gate.DEFAULT_CHECKS), gate.DEFAULT_CHECKS)
        self.assertEqual(errors, [])
        self.assertTrue(all(value == "success" for value in statuses.values()))

    def test_missing_check_blocks_release(self):
        errors, statuses = gate.evaluate(run(gate.DEFAULT_CHECKS[0], gate.DEFAULT_CHECKS[1]),
                                         gate.DEFAULT_CHECKS)
        self.assertTrue(any("no check run" in error for error in errors))
        self.assertEqual(statuses.get(gate.DEFAULT_CHECKS[2]), "missing")

    def test_skipped_and_failed_are_not_success(self):
        runs = run(gate.DEFAULT_CHECKS[0], gate.DEFAULT_CHECKS[1])
        runs.append({"name": gate.DEFAULT_CHECKS[2], "conclusion": "skipped",
                     "completed_at": "2026-11-24T11:00:00Z"})
        errors, _ = gate.evaluate(runs, gate.DEFAULT_CHECKS)
        self.assertTrue(any("conclusion=skipped" in error for error in errors))

    def test_latest_attempt_wins(self):
        runs = [
            {"name": gate.DEFAULT_CHECKS[0], "conclusion": "failure", "completed_at": "2026-11-24T09:00:00Z"},
            {"name": gate.DEFAULT_CHECKS[0], "conclusion": "success", "completed_at": "2026-11-24T10:00:00Z"},
            {"name": gate.DEFAULT_CHECKS[1], "conclusion": "success", "completed_at": "2026-11-24T10:00:00Z"},
            {"name": gate.DEFAULT_CHECKS[2], "conclusion": "success", "completed_at": "2026-11-24T10:00:00Z"},
            {"name": gate.DEFAULT_CHECKS[3], "conclusion": "success", "completed_at": "2026-11-24T10:00:00Z"},
        ]
        errors, statuses = gate.evaluate(runs, gate.DEFAULT_CHECKS)
        self.assertEqual(errors, [])
        self.assertEqual(statuses[gate.DEFAULT_CHECKS[0]], "success")

    def test_ui_check_is_required(self):
        """A UI target that never ran cannot be omitted from the release gate."""
        ui = "ui-tests · VexSignUITests (simulator)"
        self.assertIn(ui, gate.DEFAULT_CHECKS)
        errors, statuses = gate.evaluate(run(*[name for name in gate.DEFAULT_CHECKS if name != ui]),
                                         gate.DEFAULT_CHECKS)
        self.assertTrue(any(ui in error for error in errors))
        self.assertEqual(statuses[ui], "missing")

    def test_device_check_is_required_when_publishing(self):
        required = list(gate.DEFAULT_CHECKS) + [gate.DEVICE_CHECK]
        errors, statuses = gate.evaluate(run(*gate.DEFAULT_CHECKS), required)
        self.assertTrue(any("no check run" in error for error in errors))
        self.assertEqual(statuses[gate.DEVICE_CHECK], "missing")


if __name__ == "__main__":
    unittest.main()
