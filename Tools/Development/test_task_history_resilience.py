#!/usr/bin/env python3
"""Regression guard: a restarted app must not lose task history to one unreadable record.

Task history is written by one build and read by another — after an update, a downgrade, or a
TestFlight rollback. Two things make that safe, and both are easy to undo by accident:

1. **The on-disk stage names never move.** `SigningStage`'s raw values are persisted inside every
   task record. Renaming or reordering them rewrites the meaning of history that already exists.
2. **One bad record costs one record.** The journal used to decode the whole array in a single
   call, so one failure — an unfamiliar stage name, a field with the wrong type — marked the file
   corrupt, set the entire history aside and started empty. Up to 200 finished tasks, gone because
   of one entry.

This is a source check rather than a compiled test because the property is structural, and because
the Swift toolchain is not available everywhere this suite runs. The behaviour itself is covered by
`App/Tests/VexSignTests/TaskHistoryJournalTests.swift` and `App/Tests/VexSignTests/TaskSigningTraceCompatibilityTests.swift`
in CI.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SIGNING_SERVICE = ROOT / "App/iOS/VexSign/Utilities/Signing/SigningService.swift"
TASK_TRACE = ROOT / "App/iOS/VexSign/Backend/Services/TaskTrace.swift"
JOURNAL = ROOT / "App/iOS/VexSign/Backend/Services/TaskHistoryJournal.swift"
MODELS = ROOT / "App/iOS/VexSign/Backend/Observable/UnifiedTaskModels.swift"
TASK_CENTER = ROOT / "App/iOS/VexSign/Views/Download/TaskCenterView.swift"

# Append only. These strings are in every task record ever written.
FROZEN_STAGES = [
    "copying",
    "modifying",
    "thinning",
    "injecting",
    "signing",
    "verifying",
    "registering",
]


def _block(source: str, marker: str) -> str:
    start = source.index(marker)
    depth = 0
    for index in range(start, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start : index + 1]
    raise AssertionError(f"unbalanced braces after {marker!r}")


class TaskHistoryResilienceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.trace = TASK_TRACE.read_text()
        self.journal = JOURNAL.read_text()

    # ---- The on-disk form ---------------------------------------------------------------

    def test_the_persisted_stage_names_are_unchanged(self) -> None:
        block = _block(SIGNING_SERVICE.read_text(), "enum SigningStage: String, CaseIterable, Codable")
        names = re.findall(r"^\tcase (\w+)$", block, re.MULTILINE)
        self.assertEqual(
            names,
            FROZEN_STAGES,
            "SigningStage raw values are persisted in task history; append new stages, never rename",
        )

    def test_the_trace_decodes_stages_as_strings(self) -> None:
        block = _block(self.trace, "struct TaskSigningTrace")
        self.assertIn("decodeIfPresent([String].self, forKey: .stages)", block)
        self.assertNotIn("[SigningStage].self", block, "a typed stage array makes one unknown name fatal")

    def test_the_trace_keeps_its_written_field_names(self) -> None:
        block = _block(self.trace, "struct TaskSigningTrace")
        for field in ("stages", "stoppedAt", "verified", "outcome"):
            self.assertIn(f"case {field}", block, f"{field} is part of the stored trace")

    # ---- One record, not the file --------------------------------------------------------

    def test_the_journal_decodes_records_individually(self) -> None:
        load = _block(self.journal, "func load()")
        self.assertIn("JSONSerialization.jsonObject", load, "records must be split before decoding")
        self.assertNotIn(
            "decode([UnifiedTask.Snapshot].self",
            load,
            "decoding the array in one call makes a single bad record fatal for the whole file",
        )

    def test_a_salvage_preserves_the_original_before_it_is_replaced(self) -> None:
        load = _block(self.journal, "func load()")
        salvage = load[: load.index(".recordsDropped")] if ".recordsDropped" in load else ""
        self.assertIn(".recordsDropped", load, "a partial read must be distinguishable from a clean one")
        self.assertIn("io.preserve(url)", salvage, "the original must exist before the salvaged set replaces it")
        self.assertIn(".blocked(.preservationFailed)", salvage, "an unbacked-up salvage must not overwrite")

    def test_a_non_array_document_is_still_treated_as_corruption(self) -> None:
        load = _block(self.journal, "func load()")
        self.assertIn("as? [Any]", load)
        self.assertIn(".corruptPreserved", load)

    def test_the_recovery_file_name_is_stable(self) -> None:
        # The tests and any future recovery UI find the preserved copy by this prefix.
        self.assertIn('"TaskHistory-recovery-', self.journal)

    # ---- The tolerance that already existed must not regress ----------------------------

    def test_snapshot_fields_that_are_read_by_a_newer_build_stay_strings(self) -> None:
        snapshot = _block(MODELS.read_text(), "struct Snapshot: Codable")
        for field in ("kind", "phase", "failureStage"):
            self.assertRegex(
                snapshot,
                rf"var {field}: String\??",
                f"{field} is stored as a string so an unknown value can fall back instead of throwing",
            )

    # ---- The user is told ---------------------------------------------------------------

    def test_every_journal_issue_has_a_message(self) -> None:
        issues = re.search(r"case ([\w, ]+)\n", self.journal).group(1)
        names = [name.strip() for name in issues.split(",")]
        centre = TASK_CENTER.read_text()
        for name in names:
            self.assertIn(f".{name}", centre, f"Task Center has no message for journal issue {name}")


if __name__ == "__main__":
    unittest.main(verbosity=2)
