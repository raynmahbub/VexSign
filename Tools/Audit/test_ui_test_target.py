#!/usr/bin/env python3
"""Offline contracts for the real XCUITest target.

These checks keep the target, scheme, CI and evidence rules wired together. They
do not compile Swift or run an iOS simulator; only xcodebuild on macOS can do
that, and its result is reported by quality-report.py from the xcresult.
"""

import importlib.util
import json
import re
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PBX = ROOT / "VexSign.xcodeproj/project.pbxproj"
SCHEME = ROOT / "VexSign.xcodeproj/xcshareddata/xcschemes/VexSignUITests.xcscheme"
UI = ROOT / "UITests"
CI = ROOT / ".github/workflows/ci.yml"

spec = importlib.util.spec_from_file_location("vexsign_quality_report", ROOT / "Tools/Audit/quality-report.py")
quality = importlib.util.module_from_spec(spec)
spec.loader.exec_module(quality)


def pbx_object(identifier):
    match = re.search(rf"^\t\t{re.escape(identifier)} [^\n]*= \{{(.*?)^\t\t\}};",
                      PBX.read_text(), re.MULTILINE | re.DOTALL)
    if not match:
        raise AssertionError(f"pbxproj object {identifier} is missing")
    return match.group(1)


class UITestTargetTests(unittest.TestCase):
    def test_ui_target_is_a_separate_test_bundle_with_a_sibling_root(self):
        target = pbx_object("EE0000000000000000000002")
        self.assertIn('productType = "com.apple.product-type.bundle.ui-testing";', target)
        self.assertIn("productReference = EE0000000000000000000001", target)
        self.assertIn("EE0000000000000000000009 /* PBXTargetDependency */", target)
        group = pbx_object("EE000000000000000000000B")
        self.assertIn("path = UITests;", group)
        self.assertTrue((ROOT / "UITests").is_dir())
        # A nested synchronized root breaks the app target with duplicate
        # resources and an unresolved module dependency.
        self.assertFalse((ROOT / "Tests/UI").exists())

    def test_shared_scheme_tests_only_the_ui_target(self):
        root = ET.parse(SCHEME).getroot()
        references = root.findall("./TestAction/Testables/TestableReference")
        self.assertEqual(len(references), 1)
        reference = references[0]
        self.assertEqual(reference.get("skipped"), "NO")
        self.assertEqual(reference.get("parallelizable"), "NO")
        buildable = reference.find("BuildableReference")
        self.assertIsNotNone(buildable)
        self.assertEqual(buildable.get("BlueprintName"), "VexSignUITests")
        self.assertEqual(buildable.get("BlueprintIdentifier"), "EE0000000000000000000002")

    def test_ui_sources_cover_interactions_and_attach_evidence(self):
        sources = sorted(UI.glob("*.swift"))
        self.assertEqual(len(sources), 4)
        combined = "\n".join(path.read_text() for path in sources)
        self.assertIn("XCUIApplication()", combined)
        self.assertIn("XCTAttachment(screenshot:", combined)
        for interaction in ("tabBars.buttons", "swipeLeft()", "Import IPA / TIPA",
                            "Import from Files…", "Download options", "Signing Methods",
                            "Installation Engine", "waitForNavigationTitle"):
            self.assertIn(interaction, combined, f"missing UI interaction: {interaction}")
        # A simulator tap can prove an entry point exists; it cannot prove iOS
        # accepted an install. Keep that claim in the device report only.
        self.assertIn("a UI test cannot assert iOS accepted an install", combined)

    def test_launch_flag_only_dismisses_onboarding(self):
        app = (ROOT / "VexSign/App/VexSignApp.swift").read_text()
        self.assertIn('arguments.firstIndex(of: "-vexsign-ui-tests")', app)
        self.assertIn("if isUIAutomationLaunch {\n                    _onboardingCompleted = true", app)
        downloads = (ROOT / "VexSign/Features/Downloads/Views/DownloadsTabView.swift").read_text()
        self.assertIn('accessibilityLabel(Text(.localized("Download options")))', downloads)

    def test_ci_runs_the_separate_ui_target_and_keeps_evidence(self):
        ci = CI.read_text()
        self.assertIn("name: ui-tests · VexSignUITests (simulator)", ci)
        self.assertIn("-scheme VexSignUITests", ci)
        self.assertIn("-only-testing:VexSignUITests", ci)
        self.assertIn("xcrun xcresulttool get test-results tests", ci)
        self.assertIn("Upload UI xcresult, screenshots and report", ci)
        self.assertIn("needs: [quick, build, tests, ui-tests]", ci)

    def test_skipped_or_unexecuted_ui_suite_is_never_a_pass(self):
        with tempfile.TemporaryDirectory() as folder:
            results = Path(folder) / "results.json"
            results.write_text(json.dumps({"name": "VexSignUITests", "result": "skipped"}))
            report = quality.build_report(test_results=str(results))
            self.assertEqual(report["status"], "failed")
            self.assertIn("No test executed", " ".join(report["blocked"]))


if __name__ == "__main__":
    unittest.main()
