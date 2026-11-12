#!/usr/bin/env python3
"""Regression guard: no undocumented SwiftUI/framework preference overrides.

`UserDefaults` is shared with the frameworks the app links, so writing a key under
`com.apple.*` changes a framework's behaviour through a switch Apple never documented.
A build that sets `com.apple.SwiftUI.IgnoreSolariumLinkedOnCheck` (removed here) relied on
a beta-only gate: it can change meaning or disappear between releases, and the app then
silently looks different from what the same source produced before.

This checks *writes*, not reads: clearing a key an earlier build wrote is how the app
removes that reliance, so a `removeObject(forKey:)` is allowed by design.

    python3 tools/test_private_defaults_policy.py
"""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
# First-party sources only; Vendor/ and the pinned packages are upstream code.
SOURCE_ROOTS = ("VexSign", "VexSignTV", "VexSignVision", "VexSignWatch", "VexSignWatchWidgets",
                "VexSignWidgetExtension")
APPLE_PREFIX = "com.apple."

# `UserDefaults.standard.set(value, forKey: "com.apple.…")` and the subscript form.
SET_FOR_KEY = re.compile(r'\.set\(\s*[^,]+,\s*forKey:\s*"([^"]+)"')
SET_SUBSCRIPT = re.compile(r'UserDefaults[^\n]*\["([^"]+)"\]\s*=')
REMOVE = re.compile(r'removeObject\(forKey:\s*"([^"]+)"\)')


def _sources():
    for name in SOURCE_ROOTS:
        yield from sorted((ROOT / name).rglob("*.swift"))


def _strip_comments(text: str) -> str:
    """Remove `//` comments so a documented example is not read as a call."""
    lines = []
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("//"):
            continue
        lines.append(line)
    return "\n".join(lines)


class PrivateDefaultsPolicyTests(unittest.TestCase):
    def test_no_first_party_source_writes_an_apple_framework_default(self):
        offenders = []
        for path in _sources():
            text = _strip_comments(path.read_text(encoding="utf-8"))
            for pattern in (SET_FOR_KEY, SET_SUBSCRIPT):
                for key in pattern.findall(text):
                    if key.startswith(APPLE_PREFIX):
                        offenders.append(f"{path.relative_to(ROOT)}: writes {key}")
        self.assertEqual(offenders, [],
                         "use the public API and an availability check instead:\n  "
                         + "\n  ".join(offenders))

    def test_the_legacy_solarium_key_is_cleared_not_set(self):
        # The key must not survive in a container an earlier build wrote it into, which is
        # why the removal is asserted rather than only the absence of a write.
        source = _strip_comments((ROOT / "VexSign" / "VexSignApp.swift").read_text(encoding="utf-8"))
        self.assertIn('removeObject(forKey: "com.apple.SwiftUI.IgnoreSolariumLinkedOnCheck")', source)
        self.assertNotIn('set(true, forKey: "com.apple.SwiftUI.IgnoreSolariumLinkedOnCheck")', source)

    def test_the_new_guard_would_have_caught_the_old_code(self):
        # A policy test that cannot fail is decoration. Drive the matcher with the exact line
        # the app used to contain, plus the forms a future change might take.
        text = (
            'UserDefaults.standard.set(true, forKey: "com.apple.SwiftUI.IgnoreSolariumLinkedOnCheck")\n'
            'UserDefaults.standard.set(value, forKey: "com.apple.CoreData.SQLDebug")\n'
        )
        found = [key for pattern in (SET_FOR_KEY, SET_SUBSCRIPT) for key in pattern.findall(text)]
        self.assertIn("com.apple.SwiftUI.IgnoreSolariumLinkedOnCheck", found)
        self.assertIn("com.apple.CoreData.SQLDebug", found)

        cleaned = 'UserDefaults.standard.removeObject(forKey: "com.apple.SwiftUI.IgnoreSolariumLinkedOnCheck")'
        self.assertEqual(SET_FOR_KEY.findall(cleaned), [], "clearing a legacy key must stay allowed")
        self.assertIn("com.apple.SwiftUI.IgnoreSolariumLinkedOnCheck", REMOVE.findall(cleaned))

    def test_the_app_still_uses_public_material_apis(self):
        # Removing the override must not remove the effect: the surfaces that want Liquid
        # Glass have to ask for it, availability-gated.
        glass = []
        for path in _sources():
            text = path.read_text(encoding="utf-8")
            if ".glassEffect(" in text or ".glassBackgroundEffect(" in text:
                glass.append(path.relative_to(ROOT).as_posix())
        self.assertTrue(glass, "the design system should still use the public glass APIs")


if __name__ == "__main__":
    unittest.main(verbosity=2)
