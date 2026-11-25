#!/usr/bin/env python3
"""Tests for the per-feature acceptance matrix.

These tests check the harness itself. They never write a passing device report: a
synthetic fixture is rejected by the harness on purpose.
"""

import importlib.util
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("vexsign_feature_acceptance", ROOT / "Tools/Audit/feature-acceptance.py")
feature = importlib.util.module_from_spec(spec)
spec.loader.exec_module(feature)

COMMIT = "a" * 40
UNIT_EVIDENCE = "Tests/UnitTests/Signing/AutoSignIdentityPolicyTests.swift"


class FeatureAcceptanceTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.ipa = Path(self.tmp.name) / "VexSign.ipa"
        self.ipa.write_bytes(b"build-under-test")
        self.report = feature.build_report(self.ipa, COMMIT)

    def _accept(self):
        for case in self.report["cases"].values():
            case["result"] = "pass"
            case["notes"] = "Observed on the test device"
            if case["kind"] == "unit":
                case["evidence"] = UNIT_EVIDENCE
            else:
                case["tester"] = "Named Tester"
                case["device_model"] = "iPhone"
                case["os_version"] = "iOS 26.0"
                case["observed_at_utc"] = "2026-11-24T10:00:00Z"
                case["evidence"] = ""
            for scenario in case["scenarios"].values():
                scenario.update({
                    "result": "pass", "notes": case["notes"], "evidence": case["evidence"],
                    "tester": case.get("tester", ""), "device_model": case.get("device_model", ""),
                    "os_version": case.get("os_version", ""),
                    "observed_at_utc": case.get("observed_at_utc", ""),
                })
        return self.report

    def test_init_covers_every_registered_feature_as_pending(self):
        entries = feature.load_registry()
        self.assertEqual(set(self.report["cases"]), set(entries))
        self.assertGreater(len(entries), 40)
        self.assertTrue(all(case["result"] == "pending" for case in self.report["cases"].values()))
        self.assertTrue(all(
            scenario["result"] == "pending"
            for case in self.report["cases"].values()
            for scenario in case["scenarios"].values()
        ))
        self.assertEqual(self.report["ipa_sha256"], feature.sha256(self.ipa))

    def test_pending_report_is_not_acceptance(self):
        errors = feature.check_report(self.report, self.ipa, COMMIT)
        self.assertTrue(errors)
        self.assertTrue(any("result=pass" in error for error in errors))

    def test_explicit_unit_and_device_evidence_is_accepted(self):
        self.assertEqual(feature.check_report(self._accept(), self.ipa, COMMIT), [])

    def test_synthetic_notes_cannot_certify_a_device_case(self):
        report = self._accept()
        device_id = next(key for key, case in report["cases"].items() if case["kind"] == "device")
        report["cases"][device_id]["notes"] = "Synthetic fixture, not a device run"
        errors = feature.check_report(report, self.ipa, COMMIT)
        self.assertTrue(any(device_id in error and "synthetic" in error for error in errors))

    def test_artifact_or_registry_drift_invalidates_the_report(self):
        report = self._accept()
        self.ipa.write_bytes(b"different build")
        errors = feature.check_report(report, self.ipa, COMMIT)
        self.assertTrue(any("IPA checksum" in error for error in errors))

        self.ipa.write_bytes(b"build-under-test")
        report["registry_sha256"] = "0" * 64
        errors = feature.check_report(report, self.ipa, COMMIT)
        self.assertTrue(any("FeatureStatusRegistry changed" in error for error in errors))


if __name__ == "__main__":
    unittest.main()
