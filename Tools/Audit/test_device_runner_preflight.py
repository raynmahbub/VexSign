#!/usr/bin/env python3
"""Offline tests for the physical-device runner preflight gate."""

import datetime as dt
import hashlib
import importlib.util
import io
import plistlib
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / "Tools/Audit" / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


runner = load("vexsign_device_runner", "run-device-acceptance.py")
ipa_preflight = load("vexsign_device_ipa_preflight", "device_ipa_preflight.py")

COMMIT = "a" * 40
UDID = "12345678-1234567890ABCDEF1234567890ABCDEF"
IDENTITY = "iPhone Developer: Test (ABCDE12345)"


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


class DeviceIPAPreflightTests(unittest.TestCase):
    def make_ipa(self, folder, *, commit=COMMIT, udid=UDID, team="ABCDE12345",
                 channel="development", expiry_days=1, include_signature=True):
        path = Path(folder) / "VexSign-device.ipa"
        info = {
            "CFBundleIdentifier": "com.vexsign.app",
            "CFBundleExecutable": "VexSign",
            "CFBundleShortVersionString": "1.2.1",
            "CFBundleVersion": "2",
            "DTPlatformName": "iphoneos",
            "VexSignSourceCommit": commit,
            "VexSignBuildChannel": channel,
        }
        profile = {
            "ExpirationDate": dt.datetime.now(dt.timezone.utc) + dt.timedelta(days=expiry_days),
            "ProvisionedDevices": [udid],
            "TeamIdentifier": [team],
            "Entitlements": {"application-identifier": team + ".com.vexsign.app"},
        }
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("Payload/VexSign.app/Info.plist", plistlib.dumps(info))
            archive.writestr("Payload/VexSign.app/embedded.mobileprovision",
                             b"CMS(" + plistlib.dumps(profile) + b")")
            archive.writestr("Payload/VexSign.app/VexSign", b"executable")
            if include_signature:
                archive.writestr("Payload/VexSign.app/_CodeSignature/CodeResources", b"{}")
        return path

    def test_valid_development_ipa_is_accepted(self):
        with tempfile.TemporaryDirectory() as folder:
            path = self.make_ipa(folder)
            evidence, errors = ipa_preflight.check(path, COMMIT, UDID, IDENTITY)
            self.assertEqual(errors, [])
            self.assertEqual(evidence["info"]["CFBundleIdentifier"], "com.vexsign.app")

    def test_wrong_commit_device_profile_or_channel_is_refused(self):
        with tempfile.TemporaryDirectory() as folder:
            path = self.make_ipa(folder)
            self.assertTrue(any("commit" in error for error in
                                ipa_preflight.check(path, "b" * 40, UDID, IDENTITY)[1]))
            self.assertTrue(any("UDID" in error for error in
                                ipa_preflight.check(path, COMMIT, "FFFFFFFF-1234567890ABCDEF1234567890ABCDEF", IDENTITY)[1]))
            self.assertTrue(any("team" in error for error in
                                ipa_preflight.check(path, COMMIT, UDID, "iPhone Developer: X (ZZZZZZZZZZ)")[1]))
            self.assertTrue(any("application identifier" in error or "team" in error for error in
                                ipa_preflight.check(path, COMMIT, UDID, "iPhone Developer: X (ZZZZZZZZZZ)")[1]))

    def test_expired_unsigned_and_release_channel_ipas_are_refused(self):
        with tempfile.TemporaryDirectory() as folder:
            expired = self.make_ipa(folder, expiry_days=-1)
            self.assertTrue(any("expired" in error for error in
                                ipa_preflight.check(expired, COMMIT, UDID, IDENTITY)[1]))
            unsigned = Path(folder) / "unsigned.ipa"
            with zipfile.ZipFile(unsigned, "w") as archive:
                archive.writestr("Payload/VexSign.app/Info.plist", b"not a plist")
            self.assertTrue(any("Missing" in error for error in
                                ipa_preflight.check(unsigned, COMMIT, UDID, IDENTITY)[1]))
            release = self.make_ipa(folder, channel="release")
            self.assertTrue(any("channel" in error for error in
                                ipa_preflight.check(release, COMMIT, UDID, IDENTITY)[1]))

    def test_run_redacts_signing_identity_from_command_log(self):
        log = io.StringIO()
        runner.run(["/bin/true", "CODE_SIGN_IDENTITY=" + IDENTITY], log, (IDENTITY,))
        self.assertNotIn(IDENTITY, log.getvalue())
        self.assertIn("<signing identity>", log.getvalue())


if __name__ == "__main__":
    unittest.main()
