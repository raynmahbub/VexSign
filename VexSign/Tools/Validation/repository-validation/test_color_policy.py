#!/usr/bin/env python3
"""Regression guard: a colour literal lives in `DesignSystem/Colors`, nowhere else.

`DESIGN.md` says not to introduce one-off colours in a feature view, and the tree had 46 of them
— including the same log palette written twice (a SwiftUI `Color` set in `LogsView`, a `UIColor`
set in `LogConsoleView`) and the download overlay's four background presets repeated in both the
SwiftUI overlay and its UIKit sheet controller, where they could drift apart without either file
looking wrong on its own. The Flare presentation's palette, the file-root accents and the app
store banner's gradient were inline too.

The check is textual: `Color(red:`, `Color(white:`, `Color(.sRGB`, `Color(hue:` and the `UIColor`
equivalents are never right outside the token folder. A dynamic colour that needs code (a
light/dark pair, a blend of two tokens) can still be built there, and `.opacity(...)` on a token
is not a finding.

    python3 VexSign/Tools/Validation/repository-validation/test_color_policy.py
"""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
APP = ROOT / "VexSign" / "App"
ALLOWED_DIR = APP / "iOS" / "Presentation" / "DesignSystem" / "Colors"
MAKEFILE = ROOT / "Makefile"
DOC = ROOT / "VexSign" / "Documentation" / "Features" / "DESIGN.md"

LITERAL = re.compile(
    r"\b(?:Color|UIColor)\("
    r"(?:red:|white:|hue:|\.sRGB|\.displayP3|\.init\(white:)"
)


def is_comment(text: str, start: int) -> bool:
    line_start = text.rfind("\n", 0, start) + 1
    return text[line_start:start].lstrip().startswith("//")


def offending_lines(text: str) -> list[int]:
    return [
        text.count("\n", 0, match.start()) + 1
        for match in LITERAL.finditer(text)
        if not is_comment(text, match.start())
    ]


def offenders() -> list[str]:
    found: list[str] = []
    for path in sorted(APP.rglob("*.swift")):
        if path.is_relative_to(ALLOWED_DIR):
            continue
        text = path.read_text(encoding="utf-8", errors="ignore")
        found.extend(f"{path.relative_to(ROOT).as_posix()}:{line}" for line in offending_lines(text))
    return found


class ColorPolicyTests(unittest.TestCase):
    def test_a_rgb_literal_is_reported(self):
        self.assertEqual(offending_lines("Color(red: 0.1, green: 0.2, blue: 0.3)\n"), [1])

    def test_a_uicolor_literal_is_reported(self):
        self.assertEqual(offending_lines("UIColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 1)\n"), [1])

    def test_a_token_with_opacity_is_not_reported(self):
        self.assertEqual(offending_lines("Theme.Concern.tint.opacity(0.4)\n".replace("Concern", "Accent")), [])
        self.assertEqual(offending_lines("Color.accentColor\n"), [])

    def test_a_semantic_uicolor_is_not_reported(self):
        self.assertEqual(offending_lines("UIColor.secondarySystemBackground\n"), [])

    def test_a_doc_comment_is_not_a_finding(self):
        self.assertEqual(offending_lines("// Color(red: 0.1, green: 0.2, blue: 0.3)\n"), [])

    def test_the_tree_is_clean(self):
        self.assertEqual(
            offenders(),
            [],
            "name the colour in Presentation/DesignSystem/Colors (ThemePalettes.swift) instead of "
            "writing it in the view",
        )

    def test_the_gate_is_registered(self):
        self.assertTrue(
            "test_color_policy.py" in MAKEFILE.read_text(encoding="utf-8"),
            "register the gate in the Makefile's verify target",
        )

    def test_the_design_doc_names_the_gate(self):
        self.assertIn("test_color_policy.py", DOC.read_text(encoding="utf-8"))


if __name__ == "__main__":
    sys.exit(0 if unittest.main(argv=[sys.argv[0]], exit=False, verbosity=2).result.wasSuccessful() else 1)
