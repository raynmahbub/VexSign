#!/usr/bin/env python3
"""Source contracts for the release pipeline (no Xcode required)."""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class ReleaseEngineeringContracts(unittest.TestCase):
    def setUp(self):
        self.ci = (ROOT / ".github/workflows/ci.yml").read_text()
        self.release = (ROOT / ".github/workflows/release.yml").read_text()
        self.project = (ROOT / "VexSign.xcodeproj/project.pbxproj").read_text()

    def test_release_workflow_packages_and_verifies_the_artifact(self):
        for marker in [
            "Validate release configuration",
            "Generate and verify artifact manifest",
            "Tools/Release/artifact_manifest.py",
            "Tools/Release/verify_artifact.py",
            "upload/ARTIFACT.json",
            "sha256sum --check SHA256SUMS",
            "steps.xcode.outputs.xcode_version",
        ]:
            self.assertIn(marker, self.release, f"release workflow lost: {marker}")
        self.assertNotIn("pull_request:", self.release)

    def test_signed_export_is_explicitly_opt_in(self):
        for marker in [
            "signed_export:", "VEXSIGN_SIGNED_RUNNER == 'true'", "environment: release-signing",
            "export_signed_ipa.py", "--require-signature", "vexsign-signed",
        ]:
            self.assertIn(marker, self.release, f"signed export lost: {marker}")

    def test_release_workflow_uses_only_pinned_actions(self):
        for workflow in (ROOT / ".github/workflows").glob("*.yml"):
            for line in workflow.read_text().splitlines():
                if "uses: " not in line:
                    continue
                ref = line.split("uses: ", 1)[1].strip()
                if ref.startswith("./"):
                    continue
                self.assertRegex(ref, r"@[0-9a-f]{40}(?:\s|$)", f"Unpinned action in {workflow.name}: {ref}")

    def test_manifest_is_a_release_asset_and_not_a_secret_carrier(self):
        manifest = (ROOT / "Tools/Release/artifact_manifest.py").read_text()
        self.assertIn('"device_installable"', manifest)
        self.assertIn("verification_boundary", manifest)
        for forbidden in ("password", "privateKey", "apiToken"):
            self.assertNotIn(forbidden, manifest)

    def test_app_has_one_build_metadata_source(self):
        info = (ROOT / "VexSign/Shared/Build/VexSignBuildInfo.swift").read_text()
        self.assertIn("CFBundleShortVersionString", info)
        self.assertIn("VexSignBuildChannel", info)
        for path in (ROOT / "VexSign").rglob("*.swift"):
            if path.name == "VexSignBuildInfo.swift":
                continue
            self.assertNotIn("Bundle.main.version", path.read_text(), f"{path} bypasses build info")

    def test_ui_test_launch_argument_is_debug_only(self):
        app = (ROOT / "VexSign/App/VexSignApp.swift").read_text()
        self.assertIn("#if DEBUG", app)
        self.assertIn("-vexsign-ui-tests", app)
        start = app.index("private var isUIAutomationLaunch")
        end = app.index("var body:", start)
        self.assertIn("#else", app[start:end])

    def test_configurations_inject_a_channel_without_new_schemes(self):
        schemes = sorted(path.name for path in (ROOT / "VexSign.xcodeproj/xcshareddata/xcschemes").glob("*.xcscheme"))
        self.assertEqual(len(schemes), 6, "Do not add release-specific schemes without need")
        for channel in ("development", "prerelease", "release"):
            self.assertIn(f"VEXSIGN_BUILD_CHANNEL = {channel};", self.project)
        plist = (ROOT / "Config/BuildSettings/iOS/Info.plist").read_text()
        self.assertIn("<key>VexSignBuildChannel</key>", plist)

    def test_migration_is_extractable_and_tested(self):
        helper = (ROOT / "VexSign/App/Bootstrap/LegacyPreferenceMigration.swift").read_text()
        bootstrap = (ROOT / "VexSign/App/Bootstrap/AppPreferencesBootstrap.swift").read_text()
        self.assertIn("LegacyPreferenceMigration.migrate(in: .standard)", bootstrap)
        self.assertNotIn("private static func migrateLegacyUserDefaults", bootstrap)
        self.assertIn("func migrate(in defaults: UserDefaults)", helper)
        test = (ROOT / "VexSignTests/UnitTests/Application/PreferencesMigrationTests.swift").read_text()
        for case in ("testLegacyFeatherAndRyukValuesAreAdopted", "testMigrationIsIdempotentAndDoesNotOverwriteCurrentValues",
                     "testMalformedLegacyValueCannotPoisonCurrentStore"):
            self.assertIn(case, test)

    def test_quick_gate_runs_the_release_scripts(self):
        for marker in ("Tools/Release/test_release_engineering.py",
                       "Tools/Release/validate_release_config.py"):
            self.assertIn(marker, self.ci)
            self.assertIn(marker, (ROOT / "Makefile").read_text())


if __name__ == "__main__":
    unittest.main()
