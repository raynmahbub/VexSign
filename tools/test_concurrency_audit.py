#!/usr/bin/env python3
"""Fail when a concurrency escape has no documented invariant.

`tools/concurrency-discipline.py` stops the count from growing. A count cannot answer the question
that actually matters on the next code review: *why is this one safe, and what would make it unsafe?*

This is the second half. Every `@unchecked Sendable`, `nonisolated(unsafe)` and
`@preconcurrency` in the app target must appear in `tools/concurrency-audit.json` with the
synchronisation rule that makes it correct. Three things then fail the gate:

  * an escape with no audit entry      — a decision nobody wrote down
  * an audit entry whose file has none — a stale claim that quietly stopped being checked
  * an entry missing `invariant`       — a checkbox instead of a reason

Both files are consulted, so removing an escape requires updating this register in the same
commit. That is the point: the reasoning and the code move together.

Usage:

    python3 tools/test_concurrency_audit.py              # gate (exit 1 on drift)
    python3 tools/test_concurrency_audit.py --list       # what is registered, by risk
    python3 tools/test_concurrency_audit.py --self-test  # prove the checks catch drift

This does not prove isolation and does not replace the compiler. `make strict-concurrency` is the
half that actually type-checks; see also the `concurrency` job in .github/workflows/ci.yml.
"""

import argparse
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCES = ROOT / "VexSign"
AUDIT = ROOT / "tools" / "concurrency-audit.json"

PATTERNS = {
    "unchecked-sendable": re.compile(r"@unchecked\s+Sendable"),
    "nonisolated-unsafe": re.compile(r"nonisolated\(unsafe\)"),
    "preconcurrency": re.compile(r"@preconcurrency\b"),
}

REQUIRED_FIELDS = ("file", "symbol", "kind", "invariant", "risk")
REQUIRED_RISK = {"low", "medium", "high"}


def collect(root=SOURCES):
    """{relative path: [(line number, pattern name)]} — comments excluded."""
    found = {}
    for path in sorted(pathlib.Path(root).rglob("*.swift")):
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except UnicodeDecodeError:
            continue
        hits = []
        for number, line in enumerate(lines, start=1):
            if line.lstrip().startswith("//"):
                continue
            for name, pattern in PATTERNS.items():
                if pattern.search(line):
                    hits.append((number, name))
        if hits:
            try:
                key = path.relative_to(ROOT).as_posix()
            except ValueError:
                key = path.as_posix()
            found[key] = hits
    return found


def load_audit(path=AUDIT):
    return json.loads(pathlib.Path(path).read_text(encoding="utf-8")).get("escapes", [])


def check(found, escapes):
    """Returns (errors, notes). Pure so the self-test can drive it with fixtures."""
    errors, notes = [], []
    registered = {}

    for index, escape in enumerate(escapes):
        missing = [field for field in REQUIRED_FIELDS if not str(escape.get(field, "")).strip()]
        if missing:
            errors.append(
                f"audit entry #{index} ({escape.get('file', '?')} {escape.get('symbol', '?')}) "
                f"is missing {', '.join(missing)}"
            )
            continue
        if escape["risk"] not in REQUIRED_RISK:
            errors.append(
                f"audit entry #{index} ({escape['symbol']}) has risk "
                f"{escape['risk']!r}; expected one of {sorted(REQUIRED_RISK)}"
            )
        registered.setdefault(escape["file"], 0)
        registered[escape["file"]] += 1

    for path, hits in found.items():
        documented = registered.get(path, 0)
        if documented < len(hits):
            errors.append(
                f"{path}: {len(hits)} escape(s), {documented} documented in "
                f"tools/concurrency-audit.json"
            )

    for path, documented in registered.items():
        actual = len(found.get(path, []))
        if actual == 0:
            errors.append(
                f"{path}: documented in tools/concurrency-audit.json but the file has no "
                f"escape left — remove the entry"
            )
        elif documented > actual:
            errors.append(
                f"{path}: {documented} entr(ies) but only {actual} escape(s) in the file"
            )

    total = sum(len(hits) for hits in found.values())
    notes.append(f"{total} escapes across {len(found)} file(s), {len(escapes)} documented")
    return errors, notes


def self_test():
    """The gate is only worth running if it fails on drift. Prove it with fixtures."""
    escape = {
        "file": "VexSign/A.swift",
        "symbol": "A",
        "kind": "unchecked-sendable",
        "invariant": "reason",
        "risk": "low",
    }
    found = {"VexSign/A.swift": [(1, "unchecked-sendable")]}
    failures = []

    def expect_reject(label, found_fixture, entries):
        errors, _ = check(found_fixture, entries)
        if not any(label in error for error in errors):
            failures.append(f"self-test: expected a failure mentioning {label!r}, got {errors}")

    def expect_accept(label, found_fixture, entries):
        errors, _ = check(found_fixture, entries)
        if errors:
            failures.append(f"self-test: {label} should pass, got {errors}")

    expect_accept("a fully documented escape", found, [escape])
    expect_reject("0 documented", found, [])
    expect_reject("is missing invariant", found, [{**escape, "invariant": ""}])
    expect_reject("has risk", found, [{**escape, "risk": "whatever"}])
    expect_reject(
        "no escape left",
        {},
        [escape],
    )
    expect_reject(
        "entr(ies)",
        found,
        [escape, {**escape, "symbol": "A2"}],
    )
    if PATTERNS["unchecked-sendable"].search("// @unchecked Sendable in a comment"):
        pass  # matching inside a comment is filtered by collect(), not by the pattern
    return failures


def main(argv=None):
    parser = argparse.ArgumentParser(description="Every concurrency escape needs a reason.")
    parser.add_argument("--list", action="store_true", help="print the register, most risky first")
    parser.add_argument("--self-test", action="store_true", help="prove the gate catches drift")
    parser.add_argument("--audit", default=str(AUDIT), help="alternate audit file (tests)")
    parser.add_argument("--sources", default=str(SOURCES), help="alternate source root (tests)")
    arguments = parser.parse_args(argv)

    if arguments.self_test:
        failures = self_test()
        for failure in failures:
            print(f"❌ {failure}")
        if failures:
            return 1
        print("✅ concurrency audit self-test: drift is detected")
        return 0

    found = collect(arguments.sources)
    escapes = load_audit(arguments.audit)

    if arguments.list:
        order = {"high": 0, "medium": 1, "low": 2}
        for escape in sorted(escapes, key=lambda e: order.get(e.get("risk"), 3)):
            print(f"{escape.get('risk', '?'):6s}  {escape.get('symbol', '?'):32s}  {escape.get('file', '?')}")
            print(f"        {escape.get('invariant', '')}")
        return 0

    errors, notes = check(found, escapes)
    if errors:
        print(f"❌ concurrency audit: {len(errors)} problem(s)")
        for error in errors:
            print(f"  {error}")
        print()
        print("Add the reason to tools/concurrency-audit.json in the same commit — the")
        print("synchronisation rule that makes the escape correct, and what would break it.")
        return 1

    print(f"✅ concurrency audit: {notes[0]} — each with a written invariant")
    return 0


if __name__ == "__main__":
    sys.exit(main())
