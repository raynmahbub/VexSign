#!/usr/bin/env python3
"""Regression guard: UIKit feedback generators live in `Haptics`, nowhere else.

`Platform/iOS/Haptics/Haptics.swift` says it is "the app's only feedback entry point" because the
generators are UIKit objects that have to be created and fired on the main thread. The import,
download and certificate paths run off-main, so an inline generator there either does nothing or
touches UIKit from a background queue; and every inline site is a site that can never honour a
future "reduce haptics" preference.

The tree had twelve of them when this gate was written, including a `prepare()` +
`notificationOccurred(success ? .success : .error)` pair inside the platform adapter — a second
implementation of exactly what `Haptics.success()` and `Haptics.error()` are for.

The check is textual on purpose: a generator name in the app source is never correct outside the
one file, whatever the surrounding code looks like.

    python3 Tools/Validation/repository-validation/test_haptics_policy.py
"""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
APP = ROOT / "App"

# Platform targets sit beside App so their folders cannot nest inside the iOS
# synchronized root; policy scans have to cover both roots.
SCANNED = [APP, ROOT / "Platform"]
ALLOWED = APP / "iOS" / "Platform" / "iOS" / "Haptics" / "Haptics.swift"

GENERATORS = re.compile(r"\bUI(?:Impact|Notification|Selection)FeedbackGenerator\b")


def offending_lines(text: str) -> list[int]:
    return [text.count("\n", 0, match.start()) + 1 for match in GENERATORS.finditer(text)]


def offenders() -> list[str]:
    found = []
    for root in SCANNED:
        for path in sorted(root.rglob("*.swift")):
            if path == ALLOWED:
                continue
            text = path.read_text(encoding="utf-8", errors="ignore")
            for line in offending_lines(text):
                found.append(f"{path.relative_to(ROOT).as_posix()}:{line}")
    return found


class HapticsPolicyTests(unittest.TestCase):
    def test_a_generator_in_a_view_is_reported(self):
        sample = "UIImpactFeedbackGenerator(style: .light).impactOccurred()\n"
        self.assertEqual(offending_lines(sample), [1])

    def test_the_notification_generator_is_reported(self):
        sample = "let generator = UINotificationFeedbackGenerator()\ngenerator.prepare()\n"
        self.assertEqual(offending_lines(sample), [1])

    def test_a_haptics_call_is_not_reported(self):
        self.assertEqual(offending_lines("Haptics.error()\nHaptics.selection()\n"), [])

    def test_the_helper_itself_is_the_only_place_with_a_generator(self):
        self.assertEqual(
            offenders(),
            [],
            "construct feedback through Haptics (success/error/warning/selection/lightImpact): "
            "the generator has to be built and fired on the main thread, and Haptics owns that hop",
        )

    def test_the_gate_is_registered(self):
        makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
        self.assertIn("test_haptics_policy.py", makefile)


if __name__ == "__main__":
    sys.exit(0 if unittest.main(argv=[sys.argv[0]], exit=False, verbosity=2).result.wasSuccessful() else 1)
