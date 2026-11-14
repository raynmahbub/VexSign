#!/usr/bin/env python3
"""Regression tests for the localisation catalogue helpers in Tools/sync-strings.py.

The important guarantee is conservative pruning: a key Xcode marked `stale` but
that still appears as a literal in the app (for example inside `Text("…")`, which
`collect()` does not see) must never be removed.
"""

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("sync_strings", ROOT / "Tools/Development/sync-strings.py")
sync = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(sync)


def entry(state=None, langs=("en",)):
    localisations = {}
    for lang in langs:
        localisations[lang] = {"stringUnit": {"state": "translated", "value": "value"}}
    data = {"localizations": localisations}
    if state:
        data["extractionState"] = state
    return data


class StalePruningTests(unittest.TestCase):
    def test_in_use_stale_key_is_never_pruned(self):
        data = {"strings": {
            "Activity Logs": entry("stale"),          # still in the source
            "Gone for good": entry("stale"),          # absent from the source
            "Current": entry("manual"),
        }}
        blob = 'Text("Activity Logs")\nText("Current")\n'
        self.assertEqual(sync.stale_absent_keys(data, blob), ["Gone for good"])

    def test_escaped_literal_counts_as_present(self):
        data = {"strings": {'Say "hi"': entry("stale")}}
        blob = r'Text("Say \"hi\"")'
        self.assertEqual(sync.stale_absent_keys(data, blob), [])

    def test_non_stale_absent_key_is_kept(self):
        data = {"strings": {"Manual but unused": entry("manual")}}
        self.assertEqual(sync.stale_absent_keys(data, ""), [])

    def test_prune_removes_only_requested_keys_and_preserves_format(self):
        original = {
            "sourceLanguage": "en",
            "strings": {"Keep": entry("manual"), "Drop": entry("stale", langs=("en", "de"))},
            "version": "1.0",
        }
        with tempfile.TemporaryDirectory() as directory:
            catalogue = Path(directory) / "Localizable.xcstrings"
            raw = json.dumps(original, indent=2, ensure_ascii=False, separators=(",", " : ")) + "\n"
            catalogue.write_text(raw, encoding="utf-8")
            previous = sync.CATALOGUE
            try:
                sync.CATALOGUE = catalogue
                sync.prune_stale(["Drop"])
            finally:
                sync.CATALOGUE = previous
            written = catalogue.read_text(encoding="utf-8")
            data = json.loads(written)
            self.assertEqual(list(data["strings"]), ["Keep"])
            self.assertEqual(data["strings"]["Keep"], original["strings"]["Keep"])
            # Byte-identical apart from the removed entry.
            expected = json.dumps(data, indent=2, ensure_ascii=False, separators=(",", " : ")) + "\n"
            self.assertEqual(written, expected)

    def test_prune_refuses_a_key_that_is_not_present(self):
        with tempfile.TemporaryDirectory() as directory:
            catalogue = Path(directory) / "Localizable.xcstrings"
            catalogue.write_text(json.dumps({"strings": {"Keep": entry()}}), encoding="utf-8")
            previous = sync.CATALOGUE
            try:
                sync.CATALOGUE = catalogue
                with self.assertRaises(SystemExit):
                    sync.prune_stale(["Missing"])
            finally:
                sync.CATALOGUE = previous


class CoverageReportTests(unittest.TestCase):
    def setUp(self):
        self.data = {"sourceLanguage": "en", "strings": {
            "a": entry("manual", langs=("en", "de")),
            "b": entry("manual", langs=("en",)),
            "c": entry("stale", langs=("en", "de")),
        }}

    def test_counts_and_source_language_exclusion(self):
        report = sync.coverage_report(self.data)
        self.assertIn("3 keys, 1 marked stale", report)
        self.assertIn("de", report)
        self.assertNotIn(" en ", report)
        self.assertIn("66.7%", report)  # 2 of 3 keys translated into German

    def test_untranslated_state_is_not_counted(self):
        self.data["strings"]["a"]["localizations"]["de"]["stringUnit"]["state"] = "new"
        self.assertIn("33.3%", sync.coverage_report(self.data))

    def test_markdown_is_a_table(self):
        report = sync.coverage_report(self.data, markdown=True)
        self.assertIn("| Language | Translated | Missing | Coverage |", report)
        self.assertIn("| de | 2 | 1 | 66.7% |", report)

    def test_empty_catalogue_does_not_divide_by_zero(self):
        self.assertIn("0 keys", sync.coverage_report({"strings": {}}))


class LiveCatalogueTests(unittest.TestCase):
    def test_no_stale_key_that_is_still_in_the_source_would_be_pruned(self):
        data = sync.catalog()
        removable = sync.stale_absent_keys(data, sync.source_blob())
        blob = sync.source_blob()
        for key in removable:
            self.assertFalse(sync.key_in_source(key, blob))
        # Every remaining stale key is still referenced, so pruning is a no-op now.
        stale = [k for k, v in data["strings"].items() if v.get("extractionState") == "stale"]
        self.assertTrue(all(sync.key_in_source(k, blob) for k in stale if k not in removable))

    def test_catalogue_formatting_round_trips(self):
        raw = sync.CATALOGUE.read_text(encoding="utf-8")
        rendered = json.dumps(json.loads(raw), indent=2, ensure_ascii=False, separators=(",", " : ")) + "\n"
        self.assertEqual(raw, rendered)


if __name__ == "__main__":
    unittest.main()
