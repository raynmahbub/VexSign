#!/usr/bin/env python3
"""Portable contracts for the accessibility / localization / UI quality pass.

These checks catch drift that the Swift toolchain cannot see on a Linux runner:
unlabelled icon buttons, missing catalogue keys, missing UI identifiers, and CI
steps that silently stop collecting evidence. They are not a substitute for
XCUITest, Accessibility Inspector, or physical-device validation.
"""

from __future__ import annotations

import importlib.util
import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CATALOGUE = ROOT / "VexSign/Resources/Localizations/Localizable.xcstrings"
A11Y = ROOT / "VexSign/App/Navigation/State/AccessibilityIdentifiers.swift"
UI_TEST_CASE = ROOT / "VexSignTests/UITests/VexSignUITestCase.swift"
UI_ACCESSIBILITY_TEST = ROOT / "VexSignTests/UITests/AccessibilityWorkflowUITests.swift"
CI = ROOT / ".github/workflows/ci.yml"
SIMULATOR_SCRIPT = ROOT / ".github/scripts/select_simulator.py"
CHECKLIST = ROOT / "Docs/Quality/accessibility-localization-ui-2026-11.md"


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class AccessibilityContracts(unittest.TestCase):
    def test_no_unlabelled_icon_only_buttons(self):
        scanner = load_module("icon_labels", ROOT / "Tools/Validation/repository-validation/test_icon_button_labels.py")
        self.assertEqual(scanner.counts(), {}, "Every icon-only button must have a spoken label")

    def test_font_size_baseline_did_not_regress(self):
        baseline = json.loads(
            (ROOT / "Tools/Validation/repository-validation/accessibility-font-size-baseline.json").read_text()
        )
        total = sum(len(files) if isinstance(files, dict) else files for files in baseline.values())
        self.assertEqual(total, 80, "Font-size fixes must update the exact-count baseline")

    def test_feature_status_overview_is_not_hidden(self):
        source = (ROOT / "VexSign/Features/Dashboard/About/FeatureStatusView.swift").read_text()
        self.assertIn("String.localized(\"%lld source present, %lld need device validation\"", source)
        self.assertIn("'Source present' means the chain is wired, not that a build or device pass was observed", source)
        self.assertNotIn(".accessibilityHidden(true)\n\t}", source)

    def test_tap_target_helper_exists_and_is_used(self):
        style = (ROOT / "VexSign/DesignSystem/Modifiers/WorkspaceStyle.swift").read_text()
        self.assertIn("struct VexMinimumTapTarget", style)
        self.assertIn("frame(minWidth: 44, minHeight: 44)", style)
        used = [path for path in (ROOT / "VexSign/Features").rglob("*.swift")
                if ".vexsignMinimumTapTarget()" in path.read_text()]
        self.assertGreaterEqual(len(used), 3, "Compact icon buttons must use the shared target")

    def test_flare_tile_grows_with_text(self):
        source = (ROOT / "VexSign/Features/Dashboard/Home/Views/HomeFlareComponents.swift").read_text()
        self.assertIn(".frame(minHeight: 104)", source)
        self.assertIn(".fixedSize(horizontal: false, vertical: true)", source)


class LocalizationContracts(unittest.TestCase):
    def setUp(self):
        self.catalogue = json.loads(CATALOGUE.read_text(encoding="utf-8"))

    def test_english_source_and_existing_locale_set(self):
        self.assertEqual(self.catalogue["sourceLanguage"], "en")
        # The repository already carries reviewed translations in these
        # locales. No locale may be invented here; new keys stay English-only
        # until a translator reviews them.
        existing = {"ar", "cs", "de", "es", "fr", "id", "it", "pl", "ru", "tr", "vi", "zh-Hans"}
        for entry in self.catalogue["strings"].values():
            self.assertLessEqual(set(entry.get("localizations", {})), existing | {"en"})

    def test_new_labels_are_english_only_until_reviewed(self):
        new_keys = set(self.catalogue["strings"]) - set(json.loads(
            __import__("subprocess").check_output(
                ["git", "show", "HEAD:VexSign/Resources/Localizations/Localizable.xcstrings"],
                cwd=ROOT,
            )
        )["strings"])
        unexpected = {key for key in new_keys
                      if set(self.catalogue["strings"][key].get("localizations", {})) != {"en"}}
        self.assertEqual(unexpected, set(), "New strings must not ship unreviewed translations")

    def test_new_labels_are_in_the_catalogue(self):
        required = [
            "Check all certificates", "Cancel download", "Copy link",
            "Troubleshooting Center", "Operation or task ID", "Export filtered diagnostic bundle",
            "Add to favorites", "Enable automatic updates", "About DNS protection guidance",
        ]
        for key in required:
            self.assertIn(key, self.catalogue["strings"], f"{key} is not localizable")

    def test_new_count_strings_have_plural_variants(self):
        for key in [
            "%lld reported",
            "%lld structured events retained locally. The journal is bounded and rotates older data.",
            "Recorded events (%lld)",
            "%lld Updates Available",
        ]:
            en = self.catalogue["strings"][key]["localizations"]["en"]
            plural = en.get("variations", {}).get("plural", {})
            self.assertEqual(set(plural), {"one", "other"}, f"{key} needs one/other variants")
            for variant in plural.values():
                self.assertIn("%lld", variant["stringUnit"]["value"])

    def test_home_does_not_branch_on_english_plural(self):
        source = (ROOT / "VexSign/Features/Dashboard/Home/Views/HomeView.swift").read_text()
        self.assertNotIn("updateCount == 1", source)
        self.assertIn('String.localized("%lld Updates Available"', source)


class IdentifierContracts(unittest.TestCase):
    def test_diagnostics_identifiers_are_shared(self):
        production = A11Y.read_text()
        ui = UI_TEST_CASE.read_text()
        names = {
            "center": "center", "troubleshooting": "troubleshooting", "events": "events",
            "categoryfilter": "categoryFilter", "operationfilter": "operationFilter",
            "exportfiltered": "exportFiltered",
        }
        for suffix, swift_name in names.items():
            self.assertIn(f"static let {swift_name} = ", production)
            self.assertIn(f'"vexsign.diagnostics.{suffix}"', ui)

    def test_ui_accessibility_tests_use_identifiers_and_audit(self):
        source = UI_ACCESSIBILITY_TEST.read_text()
        for identifier in ["UIID.diagnosticsCenter", "UIID.troubleshooting", "UIID.categoryFilter",
                           "UIID.operationFilter", "UIID.exportFiltered"]:
            self.assertIn(identifier, source)
        self.assertIn("performAccessibilityAudit", source)
        self.assertIn("VEXSIGN_STRICT_A11Y_AUDIT", source)
        self.assertNotIn("sleep(", source, "UI tests must use expectations, not sleeps")


class CIContracts(unittest.TestCase):
    def setUp(self):
        self.ci = CI.read_text()
        self.script = SIMULATOR_SCRIPT.read_text()

    def test_oldest_supported_runtime_can_be_requested(self):
        self.assertIn("simulator_runtime:", self.ci)
        self.assertIn("--min-runtime $MIN_RUNTIME", self.ci)
        self.assertIn("--min-runtime", self.script)
        self.assertIn("def runtime_at_least", self.script)

    def test_accessibility_audit_is_configurable_and_reported(self):
        self.assertIn("strict_a11y_audit:", self.ci)
        self.assertIn("VEXSIGN_STRICT_A11Y_AUDIT:", self.ci)
        self.assertIn("Simulator configuration evidence", self.ci)

    def test_quality_contracts_run_in_quick_gate(self):
        self.assertIn("python3 Tools/Audit/test_quality_engineering_contracts.py", self.ci)
        makefile = (ROOT / "Makefile").read_text()
        self.assertIn("python3 Tools/Audit/test_quality_engineering_contracts.py", makefile)


class ManualChecklistContracts(unittest.TestCase):
    def test_iphone_checklist_does_not_claim_execution(self):
        source = CHECKLIST.read_text()
        for topic in ["VoiceOver", "Dynamic Type", "Increase Contrast", "Reduce Motion", "RTL",
                      "filtered bundle", "Instruments"]:
            self.assertIn(topic, source)
        self.assertIn("not performed here", source.lower())


if __name__ == "__main__":
    unittest.main()
