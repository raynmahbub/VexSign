#!/usr/bin/env python3
"""Regression guard: fixed point sizes do not quietly spread.

The policy is: body text uses a semantic style, and a fixed size is only right for a glyph or
numeral inside a frame that is itself fixed. The iOS tree already had 125
`.font(.system(size:` sites when this gate was written, so the rule as stated - "a handful" -
described a state that did not exist. A policy nobody can check decays into a preference, so
this gate pins the count per feature area and fails when one grows.

The comparison is exact in both directions. A growth fails, and so does a *shrinking* area: a
count that drops while the baseline keeps the old number hands that budget back to the next
change, so the improvement has to be locked in (`--update`) in the same commit that makes it.

"""

from __future__ import annotations

import json
import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
APP = ROOT / "VexSign"
# Platform targets live beside the application source root so the iOS synchronized
# root cannot claim them; their Swift files still count against the fixed-size budget.
PLATFORM = ROOT / "Platform"
BASELINE = Path(__file__).resolve().parent / "accessibility-font-size-baseline.json"

FIXED_SIZE = re.compile(r"\.font\(\.system\(size:")


def area_for(relative: Path) -> str:
    """The feature (or platform target) a file belongs to, for baselining."""
    parts = relative.parts
    if parts[0] == "Platform":
        parts = parts[1:]
    if parts[:2] == ("Features", "Dashboard"):
        return "/".join(parts[:3])
    if len(parts) > 2:
        return "/".join(parts[:2])
    return parts[0]


def counts() -> dict[str, int]:
    found: dict[str, int] = {}
    for root, prefix in ((APP, ()), (PLATFORM, ("Platform",))):
        for path in sorted(root.rglob("*.swift")):
            text = path.read_text(encoding="utf-8")
            hits = len(FIXED_SIZE.findall(text))
            if not hits:
                continue
            area = area_for(Path(*prefix) / path.relative_to(root)
                            if prefix else path.relative_to(root))
            found[area] = found.get(area, 0) + hits
    return dict(sorted(found.items()))


class AccessibilityBaselineTests(unittest.TestCase):
    def test_no_area_adds_more_fixed_point_sizes(self) -> None:
        baseline = json.loads(BASELINE.read_text(encoding="utf-8"))
        current = counts()
        grew = {
            area: (baseline.get(area, 0), count)
            for area, count in current.items()
            if count > baseline.get(area, 0)
        }
        self.assertEqual(
            grew,
            {},
            "a fixed .font(.system(size:)) was added where the surrounding frame is not fixed: "
            "use a semantic style, or justify the new size and run "
            "`python3 Tools/Validation/repository-validation/test_accessibility_baseline.py --update`",
        )

    def test_no_area_has_slack_left_in_its_budget(self) -> None:
        """
        A baseline that is higher than the tree is spent budget, not a record.

        Growth checks alone let a fixed size be removed without lowering the number,
        so the next change in that area can re-add one and still pass. Requiring the
        exact count makes `--update` part of removing a fixed size.
        """
        baseline = json.loads(BASELINE.read_text(encoding="utf-8"))
        current = counts()
        slack = {
            area: (recorded, current.get(area, 0))
            for area, recorded in baseline.items()
            if current.get(area, 0) < recorded
        }
        self.assertEqual(
            slack,
            {},
            "this area now has fewer fixed .font(.system(size:)) sites than the baseline records "
            "(baseline, current): run `python3 Tools/Validation/repository-validation/"
            "test_accessibility_baseline.py --update` in the same commit, so the freed budget "
            "cannot be spent on a new fixed size later",
        )

    def test_baseline_has_no_areas_that_no_longer_exist(self) -> None:
        baseline = json.loads(BASELINE.read_text(encoding="utf-8"))
        current = counts()
        stale = sorted(set(baseline) - set(current))
        self.assertEqual(
            stale,
            [],
            "these areas no longer contain fixed point sizes: drop them with --update",
        )

    def test_the_gate_is_registered(self) -> None:
        makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
        self.assertIn("test_accessibility_baseline.py", makefile)


def main() -> int:
    if "--update" in sys.argv[1:]:
        BASELINE.write_text(json.dumps(counts(), indent=2) + "\n", encoding="utf-8")
        print(f"wrote {BASELINE.relative_to(ROOT)}: {sum(counts().values())} fixed size(s)")
        return 0
    unittest.main(argv=[sys.argv[0]], verbosity=2)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
