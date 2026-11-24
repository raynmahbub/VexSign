#!/usr/bin/env python3
"""Regression guard: the container graph is injected in one place.

The scene and the install-queue window each spelled out the chain of `environmentObject` calls —
eighteen in `VexSignApp`, fifteen for the window, wrapped onto a single line four containers deep.
Adding a store to `AppContainer` meant remembering both, and forgetting one did not fail the
build: the window opened and crashed with "No ObservableObject of type … found" at first access.

`VexSign/App/Composition/AppEnvironment.swift` is now the only place that injects the container and the
stores built from it. Everything else reads `@Environment(\\.appContainer)` or the
`@EnvironmentObject` the modifier already placed in the environment.

The gate is textual: `.environmentObject(container…)`, `.environmentObject(appContainer…)` and
`.environment(\\.appContainer, …)` outside that file are findings. Injecting a *different* object
(a per-view model such as `TabSelectionObserver`) is not: that is local wiring, not the graph.

    python3 Tools/Validation/repository-validation/test_environment_injection_policy.py
"""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
IOS = ROOT / "VexSign" / "App"

# Platform targets sit beside the application source root so their folders cannot nest
# inside the iOS synchronized root; policy scans have to cover both roots.
SCANNED = [IOS, ROOT / "Platform"]
SHELL = IOS
ALLOWED = SHELL / "Composition" / "AppEnvironment.swift"
MAKEFILE = ROOT / "Makefile"

CONTAINER_INJECTION = re.compile(
    r"\.environmentObject\(\s*(?:app)?[Cc]ontainer(?:\s*[.)]|\s*$)",
    re.MULTILINE,
)
CONTAINER_VALUE = re.compile(r"\.environment\(\\\.appContainer,")


def is_comment(text: str, start: int) -> bool:
    line_start = text.rfind("\n", 0, start) + 1
    return text[line_start:start].lstrip().startswith("//")


def offending_lines(text: str) -> list[int]:
    hits = [
        text.count("\n", 0, match.start()) + 1
        for pattern in (CONTAINER_INJECTION, CONTAINER_VALUE)
        for match in pattern.finditer(text)
        if not is_comment(text, match.start())
    ]
    return sorted(hits)


def offenders() -> list[str]:
    found: list[str] = []
    for root in SCANNED:
        for path in sorted(root.rglob("*.swift")):
            if path == ALLOWED:
                continue
            text = path.read_text(encoding="utf-8", errors="ignore")
            found.extend(f"{path.relative_to(ROOT).as_posix()}:{line}" for line in offending_lines(text))
    return found


class EnvironmentInjectionTests(unittest.TestCase):
    def test_injecting_the_container_directly_is_reported(self):
        self.assertEqual(offending_lines(".environmentObject(appContainer)\n"), [1])

    def test_injecting_one_of_its_stores_is_reported(self):
        self.assertEqual(offending_lines(".environmentObject(container.tasks)\n"), [1])

    def test_injecting_the_environment_value_is_reported(self):
        self.assertEqual(offending_lines(".environment(\\.appContainer, container)\n"), [1])

    def test_injecting_a_view_model_is_not_reported(self):
        self.assertEqual(offending_lines(".environmentObject(tabSelection)\n"), [])

    def test_reading_the_container_is_not_reported(self):
        sample = "@Environment(\\.appContainer) private var container\n@EnvironmentObject var services: AppContainer\n"
        self.assertEqual(offending_lines(sample), [])

    def test_the_tree_has_one_injection_point(self):
        self.assertEqual(
            offenders(),
            [],
            "inject through AppEnvironment (VexSign/App/Composition/AppEnvironment.swift); read "
            "@Environment(\\.appContainer) elsewhere",
        )

    def test_the_modifier_is_used_by_both_roots(self):
        app = (SHELL / "VexSignApp.swift").read_text(encoding="utf-8")
        container = (SHELL / "Composition" / "AppContainer.swift").read_text(encoding="utf-8")
        self.assertIn("AppEnvironment(container: appContainer", app)
        self.assertIn("AppEnvironment(container: container)", container)

    def test_the_gate_is_registered(self):
        self.assertTrue(
            "test_environment_injection_policy.py" in MAKEFILE.read_text(encoding="utf-8"),
            "register the gate in the Makefile's verify target",
        )


if __name__ == "__main__":
    sys.exit(0 if unittest.main(argv=[sys.argv[0]], exit=False, verbosity=2).result.wasSuccessful() else 1)
