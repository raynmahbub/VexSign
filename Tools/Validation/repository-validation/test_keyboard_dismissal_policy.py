#!/usr/bin/env python3
"""Regression guard: a form with a text field can always dismiss the keyboard.

A `Form`/`List` filled with text fields traps the keyboard in two ways: dragging the list does
not put it away (only `ScrollView`'s default does), and the keyboard's return key may be the only
way out. `dismissableKeyboard()` wraps both fixes — `.scrollDismissesKeyboard(.interactively)`
plus a Done button above the keyboard — and `NBList`/`NBListAdaptable`, the app's own list
containers, now apply the scroll half for every screen built on them.

Before that, the helper was opt-in per screen and 21 forms with text fields had never opted in.
This gate makes the choice structural: a file that lays out text fields inside its own scroll
container must mention one of the helpers, or be listed in `PERMITTED` with a reason.

Files whose text fields are hosted by an ancestor (a dashboard embedded in a screen that owns the
scroll view) are the only legitimate exemption, and each one is written down here — a bare
name in a list is not enough.

    python3 Tools/Validation/repository-validation/test_keyboard_dismissal_policy.py
"""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
PRESENTATION = ROOT / "App/Features"
MAKEFILE = ROOT / "Makefile"

TEXT_FIELD = re.compile(r"\b(?:Text|Secure)Field\(")
# A scroll container written by the file itself, as opposed to one it is placed inside.
SCROLL_CONTAINER = re.compile(r"^[ \t]*(?:Form|List|ScrollView)[ ({]", re.MULTILINE)
HELPERS = ("NBList(", "NBListAdaptable(", "dismissableKeyboard", "scrollDismissesKeyboard")

PERMITTED = {
    # The URL field is laid out in `VexHomeDashboard`, which `HomeView` embeds inside the form that
    # carries `dismissableKeyboard()`. The dashboard's own ScrollView is horizontal, for chips.
    "Dashboard/Home/Views/VexHomeDashboard.swift": "text fields are hosted by HomeView's form, which is dismissable",
}


def is_dismissable(relative: str, text: str) -> bool:
    if not TEXT_FIELD.search(text):
        return True
    if any(helper in text for helper in HELPERS):
        return True
    if not SCROLL_CONTAINER.search(text):
        # Text fields inside an alert, or a section group rendered by a caller's list.
        return True
    return relative in PERMITTED


def findings() -> list[str]:
    reported: list[str] = []
    for path in sorted(PRESENTATION.rglob("*.swift")):
        relative = path.relative_to(PRESENTATION).as_posix()
        if not is_dismissable(relative, path.read_text(encoding="utf-8", errors="ignore")):
            reported.append(relative)
    return reported


class KeyboardDismissalTests(unittest.TestCase):
    def test_a_form_with_a_text_field_is_reported(self):
        text = "var body: some View {\n    Form {\n        TextField(\"Name\", text: $name)\n    }\n}\n"
        self.assertFalse(is_dismissable("Features/X/Views/Y.swift", text))

    def test_the_same_form_with_the_helper_is_not_reported(self):
        text = "Form {\n    TextField(\"Name\", text: $name)\n}\n.dismissableKeyboard()\n"
        self.assertTrue(is_dismissable("Features/X/Views/Y.swift", text))

    def test_an_nblist_screen_is_not_reported(self):
        text = "NBList(.localized(\"Replace\")) {\n    TextField(\"Name\", text: $name)\n}\n"
        self.assertTrue(is_dismissable("Features/X/Views/Y.swift", text))

    def test_a_field_in_an_alert_is_not_reported(self):
        text = ".alert(\"Rename\", isPresented: $showing) {\n    TextField(\"Nickname\", text: $nick)\n}\n"
        self.assertTrue(is_dismissable("Features/X/Views/Y.swift", text))

    def test_every_permitted_entry_still_exists_and_has_a_reason(self):
        for relative, reason in PERMITTED.items():
            self.assertTrue((PRESENTATION / relative).exists(), f"{relative} no longer exists")
            self.assertGreater(len(reason.strip()), 4, f"{relative} has no written reason")

    def test_the_tree_is_clean(self):
        self.assertEqual(
            findings(),
            [],
            "a form with text fields needs dismissableKeyboard(), NBList, or an entry in PERMITTED",
        )

    def test_the_gate_is_registered(self):
        self.assertTrue(
            "test_keyboard_dismissal_policy.py" in MAKEFILE.read_text(encoding="utf-8"),
            "register the gate in the Makefile's verify target",
        )


if __name__ == "__main__":
    sys.exit(0 if unittest.main(argv=[sys.argv[0]], exit=False, verbosity=2).result.wasSuccessful() else 1)
