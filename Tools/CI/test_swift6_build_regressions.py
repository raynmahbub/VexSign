#!/usr/bin/env python3
"""Portable guards for the Swift 6 build errors found on the baseline commit.

The macOS CI build and simulator test jobs both failed on `c67fab28`: one
first-party compiler warning was promoted to an error by the build gate, and one
file did not compile because `Result`'s `Failure` was `String`. These source
checks keep the repaired patterns in place on machines without Xcode; the real
type-check/build proof remains the macOS CI job.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APPLICATION = ROOT / "App/iOS/VexSign" / "Application"
VEXSIGN = ROOT / "App/iOS/VexSign"
ANISETTE_USE_CASE = APPLICATION / "AnisetteProviderUseCase.swift"
DEEP_LINK_ROUTER = APPLICATION / "DeepLinkRouterUseCase.swift"


def _strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.DOTALL)
    return re.sub(r"//.*", "", text)


def _source(path: Path) -> str:
    return _strip_comments(path.read_text(encoding="utf-8"))


class Swift6BuildRegressionTests(unittest.TestCase):
    def test_application_default_arguments_do_not_reference_isolated_singletons(self) -> None:
        # Default arguments are evaluated in a nonisolated context. A `@MainActor`
        # `.shared` there is a Swift 6 error, even though the initializer is isolated.
        isolated_default = re.compile(r"(?m)^\s*\w+\s*:\s*[^=\n]+=\s*\.shared\b")
        for path in sorted(APPLICATION.glob("*.swift")):
            with self.subTest(file=path.relative_to(ROOT).as_posix()):
                match = isolated_default.search(_source(path))
                self.assertIsNone(
                    match,
                    f"{path.relative_to(ROOT)} evaluates an actor-isolated singleton "
                    "in a default argument; resolve it inside the isolated initializer",
                )

    def test_results_never_use_string_as_failure_type(self) -> None:
        string_failure = re.compile(r"Result\s*<[^>]*,\s*String\s*>")
        for path in sorted(VEXSIGN.rglob("*.swift")):
            with self.subTest(file=path.relative_to(ROOT).as_posix()):
                self.assertIsNone(
                    string_failure.search(_source(path)),
                    f"{path.relative_to(ROOT)} uses String as Result.Failure; "
                    "Swift 6 requires a type conforming to Error",
                )

    def test_anisette_use_case_resolves_factory_inside_the_isolated_initializer(self) -> None:
        source = _source(ANISETTE_USE_CASE)
        self.assertIn("factory: AnisetteProviderFactory? = nil", source)
        self.assertIn(
            "self.factory = factory ?? AnisetteProviderFactory.shared", source
        )
        self.assertNotIn("factory: AnisetteProviderFactory = .shared", source)

    def test_coordinated_file_copy_failure_is_a_typed_error_with_its_message(self) -> None:
        source = _source(DEEP_LINK_ROUTER)
        self.assertIn(
            "private struct CoordinatedFileCopyFailure: LocalizedError", source
        )
        self.assertIn(
            "Result<Void, CoordinatedFileCopyFailure>", source
        )
        self.assertIn("reason.localizedDescription", source)
        self.assertNotIn("Result<Void, String>", source)
        # Every refusal still carries the user-visible explanation, now as a
        # LocalizedError instead of a bare String.
        self.assertGreaterEqual(source.count("CoordinatedFileCopyFailure(message:"), 3)

    def test_repository_gates_run_this_regression(self) -> None:
        command = "python3 Tools/CI/test_swift6_build_regressions.py"
        self.assertIn(command, (ROOT / "Makefile").read_text(encoding="utf-8"))
        self.assertIn(
            command, (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        )


if __name__ == "__main__":
    unittest.main()
