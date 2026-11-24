#!/usr/bin/env python3
"""Regression guard: unowned `Task.detached` work only shrinks, file by file.

`Task.detached` starts work that belongs to nobody: it survives the view, the object and the
screen that asked for it, it inherits no actor isolation, and nothing in the compiler or the
runtime will tell you when one is still running. That is sometimes exactly what is wanted — an
archive pass that must continue while a sheet closes — and sometimes how a stale write lands on a
deleted record.

The audited inventory is 77 sites across 48 files. The rule is the one the indentation ratchet
already uses, because the same trade-off applies: a whole-tree cleanup is not available, so

  * a file may not gain a `Task.detached` it did not have,
  * a new file may not arrive with one, and
  * the total may not drop without recording that it did,

so a fix cannot hand its budget to the next change. When a site is genuinely needed, the author
adds it with `--update` in the same commit, which makes the addition a reviewed line in
`detached-task-baseline.json` instead of an invisible one in a diff.

    python3 test_detached_task_audit.py [--update]

The baseline records the count per file; it deliberately does not record line numbers, which would
make every unrelated edit churn the file.
"""

from __future__ import annotations

import json
import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
SOURCE = ROOT / "VexSign"
BASELINE = Path(__file__).resolve().parent / "detached-task-baseline.json"
MAKEFILE = ROOT / "Makefile"

#: Vendored upstream trees: their concurrency is upstream's to decide.
EXCLUDED = ("VexSign/Packages/Vendor", "VexSign/Packages/SideSign", "/.build/")
DETACHED = re.compile(r"\bTask\s*\.\s*detached\b")


def first_party_files() -> list[Path]:
    files = []
    for path in SOURCE.rglob("*.swift"):
        relative = path.relative_to(ROOT).as_posix()
        if any(part in relative for part in EXCLUDED):
            continue
        files.append(path)
    return sorted(files)


def inventory() -> dict[str, int]:
    counts: dict[str, int] = {}
    for path in first_party_files():
        source = path.read_text(encoding="utf-8", errors="replace")
        # Count call sites, not comments: a line whose text before the match is a `//` or `///`
        # comment is documentation, and documenting the rule must not cost budget.
        sites = 0
        for line in source.splitlines():
            stripped = line.lstrip()
            if stripped.startswith("//") or stripped.startswith("*"):
                continue
            sites += len(DETACHED.findall(line))
        if sites:
            counts[path.relative_to(ROOT).as_posix()] = sites
    return counts


def load_baseline() -> dict:
    if not BASELINE.exists():
        return {"total": 0, "files": {}}
    return json.loads(BASELINE.read_text(encoding="utf-8"))


def write_baseline(counts: dict[str, int]) -> None:
    payload = {"total": sum(counts.values()), "files": dict(sorted(counts.items()))}
    BASELINE.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {BASELINE.name}: {payload['total']} site(s) across {len(counts)} file(s)")


class DetachedTaskAuditTests(unittest.TestCase):
    def setUp(self) -> None:
        self.counts = inventory()
        self.baseline = load_baseline()

    def test_baseline_is_not_empty(self) -> None:
        self.assertTrue(self.baseline["files"], "the audit has no inventory; run --update once")

    def test_no_file_gains_a_detached_task(self) -> None:
        grew = {
            path: (self.baseline["files"].get(path, 0), count)
            for path, count in self.counts.items()
            if count > self.baseline["files"].get(path, 0)
        }
        self.assertEqual(
            grew, {},
            "Task.detached starts work nothing owns: justify it (and record it with --update), or "
            "use Task {} / .task {} / a stored Task with cancellation",
        )

    def test_no_new_file_arrives_with_detached_work(self) -> None:
        new_files = sorted(set(self.counts) - set(self.baseline["files"]))
        self.assertEqual(new_files, [], f"new files start detached work: {new_files}")

    def test_the_total_only_shrinks_and_a_drop_is_recorded(self) -> None:
        total = sum(self.counts.values())
        self.assertLessEqual(
            total,
            self.baseline["total"],
            "the inventory grew; start no detached work without recording it",
        )
        self.assertEqual(
            total,
            self.baseline["total"],
            "the inventory shrank: record it with --update in the same commit so the next change "
            "cannot reuse the budget",
        )

    def test_the_gate_runs_in_verify(self) -> None:
        self.assertIn(
            "test_detached_task_audit.py",
            MAKEFILE.read_text(encoding="utf-8"),
            "a gate nobody runs is a comment",
        )


if __name__ == "__main__":
    if "--update" in sys.argv:
        write_baseline(inventory())
        sys.exit(0)
    unittest.main(verbosity=2)
