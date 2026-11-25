#!/usr/bin/env python3
"""Offline tests for the physical-device runner preflight gate."""

import hashlib
import importlib.util
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("vexsign_device_runner", ROOT / "Tools/Audit/run-device-acceptance.py")
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)

COMMIT = "a" * 40


class DeviceRunnerPreflightTests(unittest.TestCase):
    def test_connected_device_and_keychain_identity_are_required(self):
        listed = "Device: iPhone-UDID-1 (connected)"
        identities = '1) ABCDE12345 "iPhone Developer: Test (TEAM)"'
        self.assertEqual(runner.preflight_errors("iPhone-UDID-1", "iPhone Developer: Test (TEAM)",
                                                 COMMIT, listed, identities), [])
        errors = runner.preflight_errors("other-udid", "missing identity", COMMIT, listed, identities)
        self.assertTrue(any("not connected" in error for error in errors))
        self.assertTrue(any("not in the runner keychain" in error for error in errors))

    def test_commit_is_a_full_sha_not_a_short_ref(self):
        errors = runner.preflight_errors("udid", "identity", "abc123", "udid", "identity")
        self.assertTrue(any("40-character" in error for error in errors))

    def test_ipa_hash_is_computed_for_the_evidence_chain(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "test.ipa"
            path.write_bytes(b"vexsign-test")
            self.assertEqual(runner.sha256(path), hashlib.sha256(b"vexsign-test").hexdigest())


if __name__ == "__main__":
    unittest.main()
