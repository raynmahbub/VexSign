#!/usr/bin/env python3
"""Deterministic unit tests for the release scripts, using synthetic IPAs."""

from __future__ import annotations

import json
import plistlib
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))

import artifact_manifest  # noqa: E402
import export_signed_ipa  # noqa: E402
import release_version  # noqa: E402
import validate_release_config  # noqa: E402
import verify_artifact  # noqa: E402

COMMIT = "a" * 40


def make_ipa(directory: Path, *, version: str = "1.2.1", build: str = "2",
             channel: str = "release", commit: str = COMMIT,
             extra: dict | None = None, name: str = "VexSign-1.2.1.ipa") -> Path:
    path = directory / name
    info = {
        "CFBundleIdentifier": "com.vexsign.app",
        "CFBundleShortVersionString": version,
        "CFBundleVersion": build,
        "MinimumOSVersion": "17.0",
        "VexSignSourceCommit": commit,
        "VexSignBuildChannel": channel,
    }
    if extra:
        info.update(extra)
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr("Payload/VexSign.app/Info.plist", plistlib.dumps(info))
        archive.writestr("Payload/VexSign.app/empty", b"")
    return path


class VersionTests(unittest.TestCase):
    def test_semver_and_tags(self):
        self.assertEqual(str(release_version.parse_tag("v1.2.0-beta.1")), "1.2.0-beta.1")
        self.assertEqual(release_version.project_version_for_tag("v1.2.0-beta.1"), "1.2.0")
        self.assertTrue(release_version.is_prerelease("v1.2.0-rc.1"))
        self.assertFalse(release_version.is_prerelease("1.2.0"))
        for bad in ["1.2", "v1", "release-1.2", "v01.2.3", "v1.2.3-"]:
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                release_version.parse_tag(bad)
        self.assertEqual(release_version.build_number(123), "1.1.23")
        with self.assertRaises(ValueError):
            release_version.build_number(0)

    def test_tag_must_match_project_version(self):
        release_version.assert_tag_matches("v1.2.1-beta.1", "1.2.1")
        with self.assertRaises(ValueError):
            release_version.assert_tag_matches("v1.3.0", "1.2.1")
        with self.assertRaises(ValueError):
            release_version.assert_tag_matches("v1.2.1", "1.2.0")


class ManifestTests(unittest.TestCase):
    def setUp(self):
        self.directory = Path(tempfile.mkdtemp(prefix="vexsign-release-"))

    def manifest(self, ipa: Path, **overrides):
        values = dict(
            source_commit=COMMIT, tag="v1.2.1", xcode_version="26.3",
            swift_version="6.4.2", configuration="Release", channel="release",
            built_at="2026-11-26T12:00:00+00:00",
        )
        values.update(overrides)
        return artifact_manifest.build_manifest(ipa, **values)

    def test_manifest_checksums_and_offline_verification(self):
        ipa = make_ipa(self.directory)
        manifest = self.manifest(ipa)
        self.assertEqual(manifest["artifact"]["sha256"], artifact_manifest.sha256_file(ipa))
        self.assertFalse(manifest["signing"]["device_installable"])
        self.assertIn("No Apple signature", manifest["verification_boundary"])
        path = artifact_manifest.write_manifest(self.directory, manifest)
        sums = (self.directory / "SHA256SUMS").read_text()
        self.assertIn(manifest["artifact"]["sha256"] + "  VexSign-1.2.1.ipa", sums)
        self.assertIn("ARTIFACT.json", sums)
        report = verify_artifact.verify(ipa, path, expected_commit=COMMIT, expected_tag="v1.2.1")
        self.assertTrue(report["ok"])
        self.assertFalse(report["device_installable"])
        self.assertEqual(report["signature"], "not requested")

    def test_tampered_artifact_is_rejected(self):
        ipa = make_ipa(self.directory)
        path = artifact_manifest.write_manifest(self.directory, self.manifest(ipa))
        with zipfile.ZipFile(ipa, "a") as archive:
            archive.writestr("Payload/VexSign.app/extra", b"tampered")
        with self.assertRaisesRegex(ValueError, "SHA-256"):
            verify_artifact.verify(ipa, path)

    def test_malformed_artifacts_are_rejected(self):
        broken = self.directory / "broken.ipa"
        with zipfile.ZipFile(broken, "w") as archive:
            archive.writestr("Payload/VexSign.app/not-info.txt", b"nope")
        with self.assertRaises(ValueError):
            self.manifest(broken)
        suspicious = self.directory / "suspicious.ipa"
        with zipfile.ZipFile(suspicious, "w") as archive:
            archive.writestr("Payload/VexSign.app/Info.plist", plistlib.dumps({
                "CFBundleIdentifier": "com.vexsign.app", "CFBundleShortVersionString": "1.2.1",
                "CFBundleVersion": "2", "MinimumOSVersion": "17.0",
                "VexSignSourceCommit": COMMIT, "VexSignBuildChannel": "release",
            }))
            archive.writestr(".DS_Store", b"local file")
        with self.assertRaisesRegex(ValueError, "development-only"):
            self.manifest(suspicious)

    def test_expected_values_and_secret_like_keys_are_enforced(self):
        ipa = make_ipa(self.directory)
        path = artifact_manifest.write_manifest(self.directory, self.manifest(ipa))
        with self.assertRaises(ValueError):
            verify_artifact.verify(ipa, path, expected_commit="b" * 40)
        with self.assertRaises(ValueError):
            verify_artifact.verify(ipa, path, expected_version="9.9.9")
        leaked = json.loads(path.read_text())
        leaked["signing"]["apiToken"] = "not-a-real-token"
        path.write_text(json.dumps(leaked))
        with self.assertRaisesRegex(ValueError, "secret-like"):
            verify_artifact.load_manifest(path)

    def test_signature_requirement_fails_without_apple_tools(self):
        ipa = make_ipa(self.directory)
        path = artifact_manifest.write_manifest(self.directory, self.manifest(ipa))
        with patch.object(verify_artifact.shutil, "which", return_value=None), \
             self.assertRaisesRegex(ValueError, "codesign and security"):
            verify_artifact.verify(ipa, path, require_signature=True)
        with self.assertRaisesRegex(ValueError, "requires --require-signature"):
            verify_artifact.verify(ipa, path, require_installable=True)

    def test_invalid_manifest_inputs_fail_clearly(self):
        ipa = make_ipa(self.directory)
        with self.assertRaises(ValueError):
            self.manifest(ipa, configuration="AdHoc")
        with self.assertRaises(ValueError):
            self.manifest(ipa, channel="nightly")
        with self.assertRaises(ValueError):
            self.manifest(ipa, xcode_version="26.3\nrm -rf /")
        with self.assertRaises(ValueError):
            self.manifest(ipa, tag="v1.3.0")
        mismatched = make_ipa(self.directory, channel="development", name="VexSign-dev.ipa")
        with self.assertRaisesRegex(ValueError, "configuration"):
            self.manifest(mismatched, channel="development")

    def test_nested_bundle_must_share_namespace_and_build(self):
        bad = make_ipa(self.directory, name="VexSign-nested.ipa")
        with zipfile.ZipFile(bad, "a") as archive:
            archive.writestr("Payload/VexSign.app/PlugIns/Bad.appex/Info.plist", plistlib.dumps({
                "CFBundleIdentifier": "com.other.app", "CFBundleVersion": "2",
            }))
        with self.assertRaisesRegex(ValueError, "outside app namespace"):
            self.manifest(bad)


class SignedExportTests(unittest.TestCase):
    ENV = {
        "VEXSIGN_RELEASE_TEAM_ID": "ABCDE12345",
        "VEXSIGN_RELEASE_SIGNING_IDENTITY": "Apple Distribution: Test",
        "VEXSIGN_RELEASE_PROVISIONING_PROFILE": "VexSign release",
    }

    def test_signing_inputs_are_validated_without_logging_values(self):
        resolved = export_signed_ipa.resolve_signing_inputs(self.ENV)
        self.assertEqual(resolved["team_id"], "ABCDE12345")
        with self.assertRaises(ValueError):
            export_signed_ipa.resolve_signing_inputs({})
        with self.assertRaises(ValueError):
            export_signed_ipa.resolve_signing_inputs({**self.ENV, "VEXSIGN_RELEASE_TEAM_ID": "short"})
        options = export_signed_ipa.export_options("appStore", resolved)
        self.assertEqual(options["method"], "appStore")
        self.assertEqual(options["destination"], "upload")

    def test_dry_run_requires_an_archive_and_emits_a_secret_free_plan(self):
        with tempfile.TemporaryDirectory(prefix="vexsign-export-") as directory:
            root = Path(directory)
            archive = root / "VexSign.xcarchive"
            (archive / "Products/Applications/VexSign.app").mkdir(parents=True)
            plan = export_signed_ipa.export_signed_archive(
                archive, root / "out", "development", dict(self.ENV), dry_run=True
            )
            text = json.dumps(plan)
            self.assertNotIn("Apple Distribution: Test", text)
            self.assertNotIn("VexSign release", text)
            self.assertIn("ABCDE12345", text)
            with self.assertRaises(ValueError):
                export_signed_ipa.export_signed_archive(
                    root / "missing.xcarchive", root / "out", "adHoc", dict(self.ENV), dry_run=True
                )
            with self.assertRaises(ValueError):
                export_signed_ipa.export_signed_archive(
                    archive, root / "out", "personalTeam", dict(self.ENV), dry_run=True
                )


class ReleaseConfigTests(unittest.TestCase):
    def test_committed_project_passes_the_gate(self):
        report = validate_release_config.validate(tag="v1.2.1", build_number="2")
        self.assertEqual(report["marketing_version"], "1.2.1")
        self.assertEqual(report["configurations"]["Release"]["channel"], "release")
        self.assertEqual(report["configurations"]["Debug"]["channel"], "development")

    def test_wrong_tag_or_build_is_rejected(self):
        with self.assertRaises(ValueError):
            validate_release_config.validate(tag="v9.9.9")
        with self.assertRaises(ValueError):
            validate_release_config.validate(build_number="999")


if __name__ == "__main__":
    unittest.main()
