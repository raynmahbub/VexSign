import hashlib
import io
import json
import os
import plistlib
import shutil
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "Tools"))

from Bootstrap.environment import OSVersion, collect_environment, validate_architecture  # noqa: E402
from Bootstrap.integrity import IntegrityError, load_manifest, safe_extract_zip, verify_sha256  # noqa: E402
from Bootstrap.ipa import IPAValidationError, inspect_ipa  # noqa: E402
from Bootstrap.bootstrap import BootstrapAdapters, BootstrapContext, BootstrapState, run_bootstrap  # noqa: E402
from Bootstrap.redaction import redact  # noqa: E402


def write_ipa(path: Path, bundle_id="com.vexsign.app", version="1.0", build="1", extra_files=None):
    with zipfile.ZipFile(path, "w") as zf:
        zf.writestr("Payload/VexSign.app/", "")
        info = {
            "CFBundleIdentifier": bundle_id,
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build,
            "CFBundleName": "VexSign",
        }
        buf = io.BytesIO()
        plistlib.dump(info, buf)
        zf.writestr("Payload/VexSign.app/Info.plist", buf.getvalue())
        for name, data in (extra_files or {}).items():
            zf.writestr(name, data)


class EnvironmentTests(unittest.TestCase):
    def test_detects_supported_version(self):
        report = collect_environment(env={"VEXSIGN_IOS_VERSION": "27.0.1"}, machine="arm64", os_name="iOS")
        self.assertTrue(report.is_supported_bootstrap)
        self.assertTrue(report.ok)

    def test_rejects_old_version(self):
        report = collect_environment(env={"VEXSIGN_IOS_VERSION": "16.0"}, machine="arm64", os_name="iOS")
        self.assertFalse(report.is_supported_bootstrap)
        self.assertFalse(report.ok)

    def test_architecture_validation(self):
        validate_architecture("arm64")
        validate_architecture("arm64e")
        with self.assertRaises(Exception):
            validate_architecture("x86_64")

    def test_missing_helper_is_reported(self):
        report = collect_environment(env={"VEXSIGN_IOS_VERSION": "27.0"}, machine="arm64", os_name="iOS",
                                     helper_names=["definitely-missing-helper-xyz"])
        self.assertFalse(report.ok)
        self.assertTrue(any("definitely-missing-helper-xyz" in i for i in report.issues))

    def test_os_version_parse_rejects_invalid(self):
        for bad in ["27", "27.x", "27.0.1.2", "-1.0", "a.b"]:
            with self.assertRaises(Exception):
                OSVersion.parse(bad)


class IntegrityTests(unittest.TestCase):
    def test_checksum_verification(self):
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "a.bin"
            p.write_bytes(b"hello")
            verify_sha256(p, hashlib.sha256(b"hello").hexdigest())
            with self.assertRaises(IntegrityError):
                verify_sha256(p, "0" * 64)

    def test_manifest_rejects_malformed(self):
        with tempfile.TemporaryDirectory() as td:
            m = Path(td) / "manifest.json"
            m.write_text(json.dumps({"schema": 2, "artifacts": []}), encoding="utf-8")
            with self.assertRaises(IntegrityError):
                load_manifest(m)
            m.write_text(json.dumps({"schema": 1, "artifacts": [{"name": "a", "url": "http://bad", "sha256": "00"*32}]}), encoding="utf-8")
            with self.assertRaises(IntegrityError):
                load_manifest(m)

    def test_safe_extract_rejects_path_traversal(self):
        with tempfile.TemporaryDirectory() as td:
            td = Path(td)
            z = td / "bad.zip"
            with zipfile.ZipFile(z, "w") as zf:
                zf.writestr("../evil.txt", "bad")
            with self.assertRaises(IntegrityError):
                safe_extract_zip(z, td / "out")


class IPATests(unittest.TestCase):
    def test_inspect_valid_ipa(self):
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "app.ipa"
            write_ipa(p)
            ins = inspect_ipa(p, expected_bundle_id="com.vexsign.app")
            self.assertEqual(ins.bundle_identifier, "com.vexsign.app")
            self.assertEqual(ins.version, "1.0")

    def test_rejects_unexpected_bundle_id(self):
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "app.ipa"
            write_ipa(p, bundle_id="com.other.app")
            with self.assertRaises(IPAValidationError):
                inspect_ipa(p, expected_bundle_id="com.vexsign.app")

    def test_rejects_path_traversal(self):
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "bad.ipa"
            with zipfile.ZipFile(p, "w") as zf:
                zf.writestr("../Payload/VexSign.app/Info.plist", "bad")
            with self.assertRaises(IPAValidationError):
                inspect_ipa(p)

    def test_rejects_symlink_entry(self):
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "bad.ipa"
            with zipfile.ZipFile(p, "w") as zf:
                info = zipfile.ZipInfo("Payload/VexSign.app/Info.plist")
                info.create_system = 3
                info.external_attr = (0o120777 & 0xFFFF) << 16
                zf.writestr(info, "target")
            with self.assertRaises(IPAValidationError):
                inspect_ipa(p)

    def test_rejects_invalid_bundle_id(self):
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "app.ipa"
            write_ipa(p, bundle_id="not-a-bundle")
            with self.assertRaises(IPAValidationError):
                inspect_ipa(p)


class BootstrapStateTests(unittest.TestCase):
    def _ok_adapters(self):
        noop = lambda ctx: None
        return BootstrapAdapters(
            prepare_pairing=noop, complete_pairing=noop, verify_pairing=noop,
            authenticate=noop, provision=noop, sign=noop, verify_signature=noop,
            install=noop, confirm_install=noop, verify_launch=noop,
        )

    def test_successful_bootstrap(self):
        with tempfile.TemporaryDirectory() as td:
            ctx = BootstrapContext(work_dir=Path(td))
            result = run_bootstrap(ctx, self._ok_adapters(), env_kwargs={"env": {"VEXSIGN_IOS_VERSION": "27.0.1"}, "machine": "arm64", "os_name": "iOS"})
            self.assertEqual(result.state, BootstrapState.LAUNCH_VERIFIED)
            self.assertTrue(result.cleaned_up)

    def test_signing_failure(self):
        with tempfile.TemporaryDirectory() as td:
            adapters = self._ok_adapters()
            def fail_sign(ctx): raise RuntimeError("sign failed")
            adapters.sign = fail_sign
            ctx = BootstrapContext(work_dir=Path(td))
            result = run_bootstrap(ctx, adapters, env_kwargs={"env": {"VEXSIGN_IOS_VERSION": "27.0"}, "machine": "arm64", "os_name": "iOS"})
            self.assertEqual(result.state, BootstrapState.FAILED)
            self.assertTrue(any("sign failed" in e for e in result.errors))

    def test_installation_failure(self):
        with tempfile.TemporaryDirectory() as td:
            adapters = self._ok_adapters()
            adapters.install = lambda ctx: (_ for _ in ()).throw(RuntimeError("install failed"))
            ctx = BootstrapContext(work_dir=Path(td))
            result = run_bootstrap(ctx, adapters, env_kwargs={"env": {"VEXSIGN_IOS_VERSION": "27.0"}, "machine": "arm64", "os_name": "iOS"})
            self.assertEqual(result.state, BootstrapState.FAILED)
            self.assertTrue(any("install failed" in e for e in result.errors))

    def test_cancellation(self):
        with tempfile.TemporaryDirectory() as td:
            calls = {"n": 0}
            def cancelled():
                calls["n"] += 1
                return calls["n"] > 2
            ctx = BootstrapContext(work_dir=Path(td))
            result = run_bootstrap(ctx, self._ok_adapters(), cancelled=cancelled,
                                   env_kwargs={"env": {"VEXSIGN_IOS_VERSION": "27.0"}, "machine": "arm64", "os_name": "iOS"})
            self.assertIn(result.state, {BootstrapState.CANCELLED, BootstrapState.LAUNCH_VERIFIED, BootstrapState.FAILED})

    def test_temp_cleanup(self):
        with tempfile.TemporaryDirectory() as td:
            td = Path(td)
            tmp = td / ".vexsign-tmp-test"
            tmp.mkdir()
            (tmp / "junk").write_text("x")
            ctx = BootstrapContext(work_dir=td)
            adapters = self._ok_adapters()
            run_bootstrap(ctx, adapters, env_kwargs={"env": {"VEXSIGN_IOS_VERSION": "27.0"}, "machine": "arm64", "os_name": "iOS"})
            self.assertFalse(tmp.exists())
            self.assertTrue(ctx.cleaned_up)

    def test_malformed_release_metadata(self):
        with tempfile.TemporaryDirectory() as td:
            td = Path(td)
            manifest = td / "manifest.json"
            manifest.write_text("{not json", encoding="utf-8")
            ctx = BootstrapContext(work_dir=td, manifest_path=manifest)
            result = run_bootstrap(ctx, self._ok_adapters(), env_kwargs={"env": {"VEXSIGN_IOS_VERSION": "27.0"}, "machine": "arm64", "os_name": "iOS"})
            self.assertEqual(result.state, BootstrapState.FAILED)


class RedactionTests(unittest.TestCase):
    def test_redacts_password_token_secret(self):
        text = "password=hunter2 token=abc123 secret: shhh authorization=Bearer xyz"
        out = redact(text)
        self.assertNotIn("hunter2", out)
        self.assertNotIn("abc123", out)
        self.assertNotIn("shhh", out)
        self.assertNotIn("Bearer xyz", out)
        self.assertIn("[REDACTED]", out)

    def test_redacts_private_key(self):
        text = "-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----"
        out = redact(text)
        self.assertNotIn("abc", out)
        self.assertIn("[REDACTED]", out)


if __name__ == "__main__":
    unittest.main()
