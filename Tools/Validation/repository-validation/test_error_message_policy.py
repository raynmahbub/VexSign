#!/usr/bin/env python3
"""Regression guard: an error the user can see carries a sentence.

Three flows on this branch forwarded errors that were a bare `Error`:

* tweak injection, where `extractFile` throws `unsupportedFileExtension` and
  `TweakInjectionFailure` renders `underlying.localizedDescription`, so an unsupported
  `.rar` tweak read "Failed to inject X: The operation couldn't be completed.
  (VexSign.TweakHandlerError error 0.)";
* the Apple account session coordinator and its durable journal, whose refusals are the
  whole answer a sign-in gives when it stops.

Foundation substitutes that sentence for any error that is not `LocalizedError`, and it is
indistinguishable from a crash to the person reading it. So: every `enum ... : Error` under
`App` must either conform to `LocalizedError` (inline or in an extension), expose an
`errorDescription`/`message` property, or be listed in the baseline with the reason it never
reaches a screen.

The scanner is deliberately syntactic. It reports the type and its file, which is what an
author needs, and the baseline records the plumbing types that legitimately have no copy.

    python3 Tools/Validation/repository-validation/test_error_message_policy.py --update
"""

from __future__ import annotations

import json
import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
# Platform/ is first-party app code too; it sits beside App so its folders stay
# out of the iOS synchronized root.
APP_ROOTS = ("App", "Platform", "Shared", "Storage", "Networking", "Apple",
             "DesignSystem", "VexSign/Services")
APP = ROOT / "App"
BASELINE = Path(__file__).resolve().parent / "error-message-baseline.json"
MAKEFILE = ROOT / "Makefile"

ENUM = re.compile(r"\benum\s+(\w+)\s*:\s*([\w,\s.()]+?)\s*\{")
LOCALIZED_EXTENSION = "extension {name}:"
MESSAGE_MEMBER = re.compile(r"\bvar\s+(errorDescription|message|failureReason|recoverySuggestion)\s*:")
ERROR_CONFORMANCE = re.compile(r"\b(Error|LocalizedError)\b")


def _body(text: str, open_brace: int) -> str:
    """The body of the declaration whose `{` is at `open_brace`."""
    depth = 0
    for index in range(open_brace, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return text[open_brace:index + 1]
    return text[open_brace:]


def _label(path: Path) -> str:
    """`relative/to/repo` for a real source file; the path itself for a test fixture."""
    try:
        return path.resolve().relative_to(ROOT).as_posix()
    except ValueError:
        return str(path)


def _has_localized_extension(name: str, sources: list[str]) -> bool:
    # A nested type conforms as `extension Outer.Inner: LocalizedError`.
    pattern = re.compile(r"extension\s+(?:[\w.]+\s*\.\s*)?" + re.escape(name) + r"\s*:\s*[^\n{]*LocalizedError")
    return any(pattern.search(source) for source in sources)


def missing_messages(sources: dict[Path, str]) -> dict[str, str]:
    """`{relative/file.swift:Type: reason}` for error enums with no user-facing sentence."""
    every_source = list(sources.values())
    found: dict[str, str] = {}
    for path, text in sources.items():
        for match in ENUM.finditer(text):
            name, conformances = match.group(1), match.group(2)
            if not ERROR_CONFORMANCE.search(conformances):
                continue
            if "LocalizedError" in conformances:
                continue
            if _has_localized_extension(name, every_source):
                continue
            body = _body(text, match.end() - 1)
            if MESSAGE_MEMBER.search(body):
                continue
            found[f"{_label(path)}:{name}"] = ""
    return found


def sources() -> dict[Path, str]:
    return {
        path: path.read_text(encoding="utf-8", errors="replace")
        for root in APP_ROOTS
        for path in sorted((ROOT / root).rglob("*.swift"))
    }


class ErrorMessagePolicyTests(unittest.TestCase):
    def test_the_scanner_reports_a_bare_error_enum(self) -> None:
        text = "enum Failure: Error {\n    case one\n}\n"
        self.assertEqual(list(missing_messages({Path("X.swift"): text})), ["X.swift:Failure"])

    def test_a_localized_error_enum_passes(self) -> None:
        text = "enum Failure: LocalizedError {\n    case one\n    var errorDescription: String? { nil }\n}\n"
        self.assertEqual(missing_messages({Path("X.swift"): text}), {})

    def test_an_extension_conformance_passes(self) -> None:
        sources_map = {
            Path("A.swift"): "enum Failure: Error, Equatable {\n    case one\n}\n",
            Path("B.swift"): "extension Failure: LocalizedError {\n    var errorDescription: String? { nil }\n}\n",
        }
        self.assertEqual(missing_messages(sources_map), {})

    def test_a_message_property_passes(self) -> None:
        text = "enum Failure: Error {\n    case one\n    var message: String { \"no\" }\n}\n"
        self.assertEqual(missing_messages({Path("X.swift"): text}), {})

    def test_a_nested_type_conformance_passes(self) -> None:
        sources_map = {
            Path("A.swift"): "enum Outer {\n    enum Inner: Error {\n        case one\n    }\n}\n",
            Path("B.swift"): "extension Outer.Inner: LocalizedError {\n    var errorDescription: String? { nil }\n}\n",
        }
        self.assertEqual(missing_messages(sources_map), {})

    def test_a_localized_error_extension_written_before_the_enum_passes(self) -> None:
        sources_map = {
            Path("A.swift"): "enum Failure: Error {\n    case one\n}\n",
            Path("B.swift"): "extension Failure: LocalizedError, Equatable {}",
        }
        self.assertEqual(missing_messages(sources_map), {})

    def test_a_type_named_error_but_not_an_error_enum_is_ignored(self) -> None:
        text = "enum ErrorCode: String {\n    case one\n}\n"
        self.assertEqual(missing_messages({Path("X.swift"): text}), {})

    def test_no_new_silent_error_type(self) -> None:
        baseline = json.loads(BASELINE.read_text(encoding="utf-8"))
        new = sorted(set(missing_messages(sources())) - set(baseline))
        self.assertEqual(
            new,
            [],
            "an Error enum reaches the user without a sentence: conform it to LocalizedError and "
            "give every case an actionable `errorDescription`, or record it in "
            "error-message-baseline.json with the reason it never reaches a screen",
        )

    def test_the_baseline_records_a_reason_for_every_entry(self) -> None:
        baseline = json.loads(BASELINE.read_text(encoding="utf-8"))
        for name, reason in baseline.items():
            self.assertTrue(reason.strip(), f"{name} has no recorded reason")

    def test_the_baseline_has_no_entries_that_are_now_localized(self) -> None:
        baseline = json.loads(BASELINE.read_text(encoding="utf-8"))
        current = set(missing_messages(sources()))
        stale = sorted(set(baseline) - current)
        self.assertEqual(
            stale,
            [],
            "these types now carry a message: drop them from error-message-baseline.json with --update",
        )

    def test_the_gate_is_registered(self) -> None:
        self.assertIn("test_error_message_policy.py", MAKEFILE.read_text(encoding="utf-8"))


def baseline_with_reasons() -> dict[str, str]:
    reasons = json.loads(BASELINE.read_text(encoding="utf-8")) if BASELINE.exists() else {}
    return {name: reasons.get(name, "") for name in sorted(missing_messages(sources()))}


def main() -> int:
    if "--update" in sys.argv[1:]:
        BASELINE.write_text(json.dumps(baseline_with_reasons(), indent=2) + "\n", encoding="utf-8")
        entries = baseline_with_reasons()
        print(f"wrote {BASELINE.relative_to(ROOT)}: {len(entries)} type(s) without a user-facing message")
        return 0
    unittest.main(argv=[sys.argv[0]], verbosity=2)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
