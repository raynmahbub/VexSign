#!/usr/bin/env python3
"""Regression guard: launching an app must survive a missing LaunchServices private API.

`UIApplication.openApp(with:)` is the only way VexSign can open an installed app, and it can only
do it through private API. Two failures are possible there and both have happened in this file's
history: sending a selector the workspace does not implement terminates the app, and returning
`Void` leaves every Open button unable to tell "this iOS version cannot" from "it worked".
"""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
LAUNCH = ROOT / "Packages/NimbleKit/Sources/NimbleExtensions/UIApplication/UIApplication+open_private.swift"
ADAPTER = ROOT / "App/iOS/VexSign/Utilities/AppLauncher.swift"
# A relaunch on the way out calls `exit(0)` half a second later: there is no user left to inform,
# so it is the one place allowed to discard the answer.
INTERNAL_CALLER = ROOT / "Packages/NimbleKit/Sources/NimbleExtensions/UIApplication/UIApplication+suspend.swift"


def _open_app_declaration() -> str:
    source = LAUNCH.read_text()
    match = re.search(r"static public func openApp\(with identifier: String\) -> Bool \{(.*?)\n\t\}", source, re.DOTALL)
    if match is None:
        raise AssertionError("openApp must keep the `-> Bool` contract callers branch on")
    return match.group(1)


class PrivateLaunchPolicyTests(unittest.TestCase):
    def test_open_app_checks_both_selectors_before_sending_them(self) -> None:
        body = _open_app_declaration()
        self.assertIn("class_getClassMethod(workspaceClass, NSSelectorFromString(defaultSelector)) != nil", body)
        self.assertIn("workspace.responds(to: selector)", body)
        self.assertIn("workspace.method(for: selector)", body)
        self.assertIn("guard !identifier.isEmpty else { return false }", body)

    def test_open_app_dispatches_the_primitive_return_through_its_real_convention(self) -> None:
        body = _open_app_declaration()
        self.assertIn("@convention(c) (AnyObject, Selector, NSString) -> Void", body)
        # `openApplicationWithBundleID:` returns a BOOL, not an object: routing it back through
        # `perform(_:with:)` would reinterpret that BOOL as a pointer.
        self.assertNotIn("workspace.perform(NSSelectorFromString(openSelector)", body)

    def test_open_app_reports_unavailability_instead_of_returning_nothing(self) -> None:
        body = _open_app_declaration()
        self.assertTrue(body.count("return false") >= 3, body.count("return false"))
        self.assertIn("return true", body)
        self.assertIn("@discardableResult", LAUNCH.read_text())

    def test_the_adapter_tells_the_user_when_a_launch_could_not_be_dispatched(self) -> None:
        source = ADAPTER.read_text()
        self.assertIn("guard UIApplication.openApp(with: identifier) else", source)
        self.assertEqual(source.count("Toast.error("), 2,
                         "both the empty identifier and the unavailable private API need a report")
        self.assertIn("guard !identifier.isEmpty else", source)

    def test_no_user_facing_open_button_discards_the_launch_result(self) -> None:
        direct = []
        for path in ROOT.rglob("*.swift"):
            if ".build" in path.parts or ".git" in path.parts:
                continue
            if path in (LAUNCH, ADAPTER, INTERNAL_CALLER):
                continue
            # The rule is about buttons a person presses. A test that calls the primitive directly
            # is testing it, not shipping it.
            if path.name.endswith("Tests.swift") or any(
                part.endswith("Tests") for part in path.relative_to(ROOT).parts
            ):
                continue
            if "UIApplication.openApp(" in path.read_text():
                direct.append(str(path.relative_to(ROOT)))
        self.assertEqual(direct, [], "route user-facing launches through AppLauncher so a failure is reported")

    def test_install_progress_keeps_degrading_to_unknown(self) -> None:
        source = LAUNCH.read_text()
        self.assertIn("func installProgress(", source)
        self.assertIn("-> Double?", source)
        self.assertIn("fraction.isFinite", source)
        self.assertNotIn("fractionCompleted ?? 0", source)


if __name__ == "__main__":
    unittest.main()
