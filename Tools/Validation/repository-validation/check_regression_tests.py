#!/usr/bin/env python3
"""Fail an app-source change that ships without a regression test.

A bug fix that only changes production code is a claim, not a regression test.
This gate compares the current commit with its base and fails when first-party
app/package source changed but no test file did. It runs in CI's quick job, where
the full history is checked out; with no usable base it says so instead of
pretending a test existed.

This is a coarse coverage gate, not proof that the new test covers the fix. The
reviewer still owns that judgement; the compiler and test jobs own execution.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import unittest
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parents[3]
TEST_PREFIXES = ("Tests/", "UITests/", "Services/Integrations/tests/")


def is_test(path: str) -> bool:
    name = PurePosixPath(path).name
    return path.startswith(TEST_PREFIXES) or name.startswith("test_") or name.endswith("Tests.swift")


def is_app_source(path: str) -> bool:
    if is_test(path):
        return False
    return path.startswith(("VexSign/", "Platform/", "Packages/", "Services/Integrations/"))


def evaluate(paths: list[str]) -> list[str]:
    sources = sorted({path for path in paths if is_app_source(path)})
    if not sources:
        return []
    tests = sorted({path for path in paths if is_test(path)})
    if tests:
        return []
    return [
        "Changed first-party source without a regression test:",
        *("  - " + path for path in sources[:20]),
        "Add or modify a test in Tests/, UITests/ or the affected package's test suite.",
    ]


def base_sha() -> str:
    event_name = os.environ.get("GITHUB_EVENT_NAME", "")
    event_path = os.environ.get("GITHUB_EVENT_PATH", "")
    if event_path:
        try:
            event = json.loads(Path(event_path).read_text(encoding="utf-8"))
            if event_name == "pull_request":
                value = event["pull_request"]["base"]["sha"]
            elif event_name == "push":
                value = event["before"]
            else:
                value = ""
            if len(value) == 40 and all(c in "0123456789abcdef" for c in value) and set(value) != {"0"}:
                return value
        except (KeyError, OSError, ValueError, json.JSONDecodeError):
            pass
    try:
        base = subprocess.check_output(
            ["git", "merge-base", "HEAD", "origin/main"], cwd=ROOT, text=True
        ).strip()
        if len(base) == 40:
            return base
    except (OSError, subprocess.CalledProcessError):
        pass
    # The branch was cut from a commit that main has since rewritten, so there
    # is no common ancestor. The previous commit is still the best portable
    # comparison for a local check; CI uses the immutable PR base instead.
    try:
        base = subprocess.check_output(["git", "rev-parse", "HEAD^"], cwd=ROOT, text=True).strip()
        return base if len(base) == 40 else ""
    except (OSError, subprocess.CalledProcessError):
        return ""


def changed_paths(base: str) -> list[str]:
    if not base:
        return []
    output = subprocess.check_output(
        ["git", "diff", "--name-only", "--no-renames", "-z", base, "HEAD"],
        cwd=ROOT,
    )
    return [item.decode("utf-8") for item in output.split(b"\0") if item]


class RegressionPolicyTests(unittest.TestCase):
    def test_source_without_test_fails(self):
        self.assertTrue(evaluate(["VexSign/Services/Foo.swift"]))

    def test_ui_test_counts_as_a_regression_test(self):
        self.assertEqual(evaluate(["VexSign/Services/Foo.swift", "UITests/FooUITests.swift"]), [])

    def test_docs_and_gate_scripts_are_not_app_source(self):
        self.assertEqual(evaluate(["README.md", "Tools/Audit/check.py"]), [])

    def test_tools_are_not_silently_exempt_when_they_are_tests(self):
        self.assertTrue(is_test("Tools/Audit/test_quality_report.py"))
        self.assertFalse(is_app_source("Tools/Audit/test_quality_report.py"))


def main() -> int:
    if "--self-test" in sys.argv:
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(RegressionPolicyTests)
        result = unittest.TextTestRunner(verbosity=2).run(suite)
        return 0 if result.wasSuccessful() else 1
    base = base_sha()
    if not base:
        print("No comparable base; regression-test gate cannot inspect this checkout")
        return 0
    problems = evaluate(changed_paths(base))
    if problems:
        print("\n".join(problems), file=sys.stderr)
        return 1
    print(f"Regression-test gate OK against {base[:12]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
