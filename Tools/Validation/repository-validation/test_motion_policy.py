#!/usr/bin/env python3
"""Regression guard: motion goes through `AppMotion`, never around it.

`VexSign/DesignSystem/Modifiers/AppMotion.swift` exists because the tree carried two idioms: 46 files
calling `withAnimation(.spring(response: 0.35, dampingFraction: 0.85))` verbatim, which ignored
Reduce Motion entirely, and a few views writing `_reduceMotion ? nil : .smooth` by hand, which
was correct but only for the call sites that remembered. Downloads, the app store, the signing
sheet and the toast all animated for users who had asked the system to stop.

Two rules follow from that, and both are mechanical:

* `withAnimation(` is never correct — it has no way to see the setting. Use
  `withAppAnimation(...)`, which drops the animation and still runs the body.
* `.animation(_:value:)` is only correct with a `nil` curve, which is how a view says "never
  animate this". Anything else should be `.appAnimation(...)`.

The `VexSign/DesignSystem/Modifiers` folder is exempt: it is where `AppMotion` is implemented (its own
body calls `withAnimation`, because that is the API it wraps), and the one legitimate `.animation`
there is `AppStyle`'s press effect, which resolves the setting inline and has a theme-dependent
curve.

    python3 Tools/Validation/repository-validation/test_motion_policy.py
"""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
APP = ROOT / "VexSign"

# Platform targets sit beside the application source root so their folders cannot nest
# inside the iOS synchronized root; policy scans have to cover both roots.
SCANNED = [APP, ROOT / "Platform"]
ALLOWED_DIRS = (
    # Where the motion primitives live: `withAppAnimation` and `.appAnimation`.
    APP / "DesignSystem" / "Modifiers",
    # The flare button's press animation is part of the style it belongs to, and it reads
    # `accessibilityReduceMotion` itself before choosing a curve.
    APP / "DesignSystem" / "Styles" / "AppStyle.swift",
)

BARE_WITH_ANIMATION = re.compile(r"\bwithAnimation\(")
ANIMATION_MODIFIER = re.compile(r"(?<![\w])\.animation\(")


def first_argument(text: str, open_paren: int) -> str:
    """The text between `text[open_paren] == "("` and its matching `)`."""
    depth = 0
    for index in range(open_paren, len(text)):
        character = text[index]
        if character == "(":
            depth += 1
        elif character == ")":
            depth -= 1
            if depth == 0:
                return text[open_paren + 1 : index]
    raise ValueError("unbalanced parentheses")


def is_comment(text: str, start: int) -> bool:
    line_start = text.rfind("\n", 0, start) + 1
    return text[line_start:start].lstrip().startswith("//")


def findings_in(text: str, *, check_bare: bool = True, check_modifier: bool = True) -> list[int]:
    reported: list[int] = []
    if check_bare:
        for match in BARE_WITH_ANIMATION.finditer(text):
            if not is_comment(text, match.start()):
                reported.append(text.count("\n", 0, match.start()) + 1)
    if check_modifier:
        for match in ANIMATION_MODIFIER.finditer(text):
            if is_comment(text, match.start()):
                continue
            argument = first_argument(text, match.end() - 1).strip()
            if argument == "nil" or argument.startswith("nil,"):
                continue
            reported.append(text.count("\n", 0, match.start()) + 1)
    return sorted(reported)


def findings() -> list[str]:
    reported: list[str] = []
    for root in SCANNED:
        for path in sorted(root.rglob("*.swift")):
            text = path.read_text(encoding="utf-8", errors="ignore")
            is_design_system = any(path == allowed or path.is_relative_to(allowed)
                                   for allowed in ALLOWED_DIRS)
            lines = findings_in(text, check_bare=not is_design_system,
                                check_modifier=not is_design_system)
            reported.extend(f"{path.relative_to(ROOT).as_posix()}:{line}" for line in lines)
    return reported


class MotionPolicyTests(unittest.TestCase):
    def test_a_bare_with_animation_is_reported(self):
        self.assertEqual(findings_in("withAnimation(.snappy) { open.toggle() }\n"), [1])

    def test_with_app_animation_is_not_reported(self):
        self.assertEqual(findings_in("withAppAnimation(.snappy) { open.toggle() }\n"), [])

    def test_a_curve_on_the_animation_modifier_is_reported(self):
        sample = '.animation(.spring(response: 0.3, dampingFraction: 0.8), value: open)\n'
        self.assertEqual(findings_in(sample), [1])

    def test_nil_is_allowed(self):
        self.assertEqual(findings_in(".animation(nil, value: progress)\n"), [])

    def test_a_doc_comment_is_not_a_finding(self):
        self.assertEqual(findings_in("// withAnimation(.snappy) would ignore Reduce Motion\n"), [])
        self.assertEqual(findings_in("/// Never spell it withAnimation( again.\n"), [])

    def test_the_tree_is_clean(self):
        self.assertEqual(
            findings(),
            [],
            "route motion through AppMotion: withAppAnimation(...) instead of withAnimation(...), "
            "and .appAnimation(...) instead of .animation(someCurve, value:)",
        )

    def test_the_gate_is_registered(self):
        makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
        self.assertIn("test_motion_policy.py", makefile)


if __name__ == "__main__":
    sys.exit(0 if unittest.main(argv=[sys.argv[0]], exit=False, verbosity=2).result.wasSuccessful() else 1)
