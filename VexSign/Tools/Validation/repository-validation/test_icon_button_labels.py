#!/usr/bin/env python3
"""Regression guard: icon-only buttons have a name.

`Documentation/Development/ACCESSIBILITY.md` §2 requires every `Button` whose label is only an
`Image(systemName:)` to carry an `.accessibilityLabel`, because VoiceOver otherwise announces
"button" and nothing else. That rule was a review item, and review items decay: the tree held
47 unlabelled icon-only buttons when this gate was written.

The scan is structural rather than textual: it brace-matches the action and `label:` closures of
each `Button` and only reports a closure whose entire body is an `Image(systemName:)` (with
modifiers) and which carries no `Text`, `Label`, `title:` or `.accessibilityLabel`. A button
whose label is a custom component, or which already has text, is not reported — the point is a
signal an author can act on, not a count.

Like the font-size baseline this is a ratchet in both directions: growth fails, and so does a
drop that was not locked in, so the improvement cannot be spent again by the next edit. Keying
is per file, because line numbers move under unrelated edits.

An opt-out exists for the rare case where a label is supplied by something other than the
button itself. It must carry a reason: `// a11y: decorative: <why>` with at least four
characters after the marker. A bare marker counts as a finding, so it cannot be used to silence
the gate quietly.

    python3 VexSign/Tools/Validation/repository-validation/test_icon_button_labels.py --update
"""

from __future__ import annotations

import json
import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
APP = ROOT / "VexSign" / "App"
BASELINE = Path(__file__).resolve().parent / "accessibility-icon-button-baseline.json"
DOC = ROOT / "VexSign" / "Documentation" / "Development" / "ACCESSIBILITY.md"
MAKEFILE = ROOT / "Makefile"

ICON = re.compile(r"^\s*Image\(\s*systemName:", re.M)
TEXTUAL = re.compile(r"\bText\(|\bLabel\(|\btitle:|\.accessibilityLabel\s*\(")
OPT_OUT = re.compile(r"//\s*a11y:\s*decorative(?:[:\u2014-]+\s*(\S.*))?")
ACTION_START = re.compile(r"\bButton\s*(?:\([^)]*\))?\s*\{")
ACTION_LABEL_START = re.compile(r"\bButton\s*\(\s*action:\s*\{")


def _match_brace(text: str, index: int) -> int:
    """Return the offset just past the `}` matching the `{` at `index`, or -1."""
    depth = 0
    i = index
    while i < len(text):
        char = text[i]
        if char == '"':
            i += 1
            while i < len(text) and text[i] != '"':
                if text[i] == "\\":
                    i += 1
                i += 1
        elif char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return -1


def _closures(text: str, pattern: re.Pattern[str]) -> list[tuple[int, int]]:
    spans: list[tuple[int, int]] = []
    for match in pattern.finditer(text):
        brace = text.find("{", match.end() - 1)
        if brace < 0:
            continue
        end = _match_brace(text, brace)
        if end > 0:
            spans.append((match.start(), end))
    return spans


def _label_closures(text: str) -> list[tuple[int, int]]:
    spans: list[tuple[int, int]] = []
    for match in re.finditer(r"\blabel:\s*\{", text):
        end = _match_brace(text, text.find("{", match.end() - 1))
        if end > 0:
            spans.append((match.start(), end))
    return spans


def scan(source: str) -> list[int]:
    """Return the 1-based line numbers of icon-only buttons with no accessible name."""
    # `Button(action: {` matches both patterns; dedupe so a site is counted once.
    actions = sorted(set(_closures(source, ACTION_START) + _closures(source, ACTION_LABEL_START)))
    labels = _label_closures(source)
    findings: list[int] = []
    for start, end in actions:
        label = next(((ls, le) for ls, le in labels if end <= ls < end + 40), None)
        if label is None:
            continue
        body = source[label[0]:label[1]]
        if not ICON.search(body) or TEXTUAL.search(body):
            continue
        # A name may be attached to the button rather than inside its label closure:
        # `Button { … } label: { Image(…) }.accessibilityLabel(…)`. Look just past the
        # closure, stopping at the next Button so an unrelated label cannot mask this one.
        tail = source[label[1]:label[1] + 400]
        next_button = tail.find("Button")
        if next_button >= 0:
            tail = tail[:next_button]
        if ".accessibilityLabel" in tail:
            continue
        exempt = OPT_OUT.search(source[max(0, start - 240):start]) or OPT_OUT.search(body)
        if exempt and exempt.lastindex and exempt.group(1) and len(exempt.group(1).strip()) >= 4:
            continue
        findings.append(source.count("\n", 0, start) + 1)
    return findings


def counts() -> dict[str, int]:
    found: dict[str, int] = {}
    for path in sorted(APP.rglob("*.swift")):
        hits = scan(path.read_text(encoding="utf-8", errors="replace"))
        if hits:
            found[str(path.relative_to(APP))] = len(hits)
    return dict(sorted(found.items()))


class IconButtonLabelTests(unittest.TestCase):
    def test_the_scanner_reports_an_icon_only_button(self) -> None:
        source = (
            "Button { collapse() } label: {\n"
            "    Image(systemName: \"chevron.down\")\n"
            "        .font(.caption)\n"
            "}\n"
        )
        self.assertEqual(scan(source), [1])

    def test_the_scanner_accepts_a_labelled_button(self) -> None:
        source = (
            "Button { collapse() } label: {\n"
            "    Image(systemName: \"chevron.down\")\n"
            "}\n"
            ".accessibilityLabel(Text(.localized(\"Collapse downloads\")))\n"
        )
        self.assertEqual(scan(source), [])

    def test_text_and_label_labels_are_names(self) -> None:
        for body in ("Text(\"Close\")", "Label(\"Close\", systemImage: \"xmark\")"):
            source = f"Button {{ close() }} label: {{\n    {body}\n}}\n"
            self.assertEqual(scan(source), [], body)

    def test_nested_closures_do_not_confuse_the_matcher(self) -> None:
        source = (
            "Button {\n"
            "    if ready { start() } else { queue() }\n"
            "} label: {\n"
            "    Image(systemName: \"play.fill\")\n"
            "}\n"
        )
        self.assertEqual(scan(source), [1])

    def test_an_image_outside_a_button_is_not_a_finding(self) -> None:
        self.assertEqual(scan("Image(systemName: \"star\")\n"), [])

    def test_a_reasoned_opt_out_is_honoured(self) -> None:
        source = (
            "// a11y: decorative: renamed by the enclosing picker row\n"
            "Button { pick() } label: {\n"
            "    Image(systemName: \"chevron.right\")\n"
            "}\n"
        )
        self.assertEqual(scan(source), [])

    def test_a_bare_opt_out_does_not_silence_the_gate(self) -> None:
        source = (
            "// a11y: decorative\n"
            "Button { pick() } label: {\n"
            "    Image(systemName: \"chevron.right\")\n"
            "}\n"
        )
        self.assertEqual(scan(source), [2])

    def test_no_file_adds_a_new_unlabelled_icon_button(self) -> None:
        baseline = json.loads(BASELINE.read_text(encoding="utf-8"))
        current = counts()
        grew = {
            path: (baseline.get(path, 0), count)
            for path, count in current.items()
            if count > baseline.get(path, 0)
        }
        self.assertEqual(
            grew,
            {},
            "an icon-only Button was added without an accessible name (baseline, current): "
            "add `.accessibilityLabel(Text(.localized(\"...\")))` to the button, or a reasoned "
            "`// a11y: decorative: <why>` opt-out, and run "
            "`python3 VexSign/Tools/Validation/repository-validation/test_icon_button_labels.py --update`",
        )

    def test_no_file_keeps_a_budget_it_no_longer_uses(self) -> None:
        baseline = json.loads(BASELINE.read_text(encoding="utf-8"))
        current = counts()
        slack = {
            path: (recorded, current.get(path, 0))
            for path, recorded in baseline.items()
            if current.get(path, 0) < recorded
        }
        self.assertEqual(
            slack,
            {},
            "this file has fewer unlabelled icon buttons than the baseline records "
            "(baseline, current): lock the improvement in with "
            "`python3 VexSign/Tools/Validation/repository-validation/test_icon_button_labels.py --update`",
        )

    def test_the_baseline_has_no_files_that_no_longer_exist(self) -> None:
        baseline = json.loads(BASELINE.read_text(encoding="utf-8"))
        stale = sorted(set(baseline) - set(counts()))
        self.assertEqual(stale, [], "these files are gone or clean: drop them with --update")

    def test_the_rule_is_documented(self) -> None:
        doc = DOC.read_text(encoding="utf-8")
        self.assertIn("test_icon_button_labels.py", doc)
        self.assertIn("accessibility-icon-button-baseline.json", doc)

    def test_the_gate_is_registered(self) -> None:
        self.assertIn("test_icon_button_labels.py", MAKEFILE.read_text(encoding="utf-8"))


def main() -> int:
    if "--update" in sys.argv[1:]:
        BASELINE.write_text(json.dumps(counts(), indent=2) + "\n", encoding="utf-8")
        print(f"wrote {BASELINE.relative_to(ROOT)}: {sum(counts().values())} unlabelled icon button(s)")
        return 0
    unittest.main(argv=[sys.argv[0]], verbosity=2)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
