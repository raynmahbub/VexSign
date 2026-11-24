#!/usr/bin/env python3
"""Regression guard: the tab-indented Swift backlog only shrinks.

`.swiftformat` now says four spaces, and `indent` — the rule that converts indentation — is
enabled. The whole-tree pass has not happened: 552 of 1,178 first-party files still indent with
tabs, so
`swiftformat --lint .` cannot be a CI gate without failing every pull request over code it never
touched, which is why that step is still report-only (`continue-on-error: true`). The enforcing
halves are `check-swift-format-drift.py` for the lines a diff owns, and this ratchet for the
backlog as a whole.

A ratchet in both directions, like the accessibility baselines: a new tab-indented file fails,
and so does a drop that was not recorded, so a cleanup cannot quietly hand its budget to the next
change. The one legitimate way to make the count smaller is to reformat files and run

    python3 Tools/Validation/repository-validation/test_swift_indentation_ratchet.py --update

in the same commit. When the count reaches zero, replace this gate with `swiftformat --lint .` and
delete the report-only step.
"""

from __future__ import annotations

import json
import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SOURCE = ROOT
BASELINE = Path(__file__).resolve().parent / "swift-indentation-baseline.json"
MAKEFILE = ROOT / "Makefile"

#: Vendored upstream trees, which `.swiftformat` excludes: their indentation is upstream's.
EXCLUDED = ("Packages/Vendor", "Packages/SideSign", "/.build/")
TAB_INDENTED = re.compile(r"^\t", re.MULTILINE)


def first_party_files() -> list[Path]:
    files = []
    for path in sorted(SOURCE.rglob("*.swift")):
        relative = path.relative_to(ROOT).as_posix()
        if any(marker in relative for marker in EXCLUDED):
            continue
        files.append(path)
    return files


def counts() -> dict[str, int]:
    files = first_party_files()
    return {
        "files": sum(1 for path in files if TAB_INDENTED.search(path.read_text(encoding="utf-8", errors="ignore"))),
        "total": len(files),
    }


def is_tab_indented(text: str) -> bool:
    return TAB_INDENTED.search(text) is not None


class SwiftIndentationRatchetTests(unittest.TestCase):
    def test_a_tab_indented_file_is_counted(self):
        self.assertTrue(is_tab_indented("struct A {\n\tlet x = 1\n}\n"))

    def test_a_space_indented_file_is_not(self):
        self.assertFalse(is_tab_indented("struct A {\n    let x = 1\n}\n"))

    def test_a_tab_inside_a_string_does_not_count(self):
        # A tab at the start of a *line* inside a multiline string literal is rare enough that
        # counting it keeps the rule simple; this test documents the choice rather than hiding it.
        self.assertTrue(is_tab_indented('let s = """\n\thello\n"""\n'))

    def test_no_new_tab_indented_file(self):
        baseline = json.loads(BASELINE.read_text(encoding="utf-8"))
        current = counts()
        self.assertLessEqual(
            current["files"],
            baseline["files"],
            "a new file indents with tabs: use four spaces (.swiftformat sets `indent 4`), or "
            "reformat it; the backlog is recorded in swift-indentation-baseline.json",
        )

    def test_the_backlog_is_recorded_not_spent(self):
        baseline = json.loads(BASELINE.read_text(encoding="utf-8"))
        current = counts()
        self.assertGreaterEqual(
            current["files"],
            baseline["files"],
            "fewer tab-indented files than recorded: run this gate with --update in the same "
            "commit so the freed budget cannot be spent on a new one",
        )

    def test_the_gate_is_registered(self):
        self.assertTrue(
            "test_swift_indentation_ratchet.py" in MAKEFILE.read_text(encoding="utf-8"),
            "register the gate in the Makefile's verify target",
        )


def main() -> int:
    if "--update" in sys.argv[1:]:
        current = counts()
        BASELINE.write_text(json.dumps(current, indent=2) + "\n", encoding="utf-8")
        print(f"wrote {BASELINE.relative_to(ROOT)}: {current['files']} of {current['total']} files")
        return 0
    unittest.main(argv=[sys.argv[0]], verbosity=2)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
