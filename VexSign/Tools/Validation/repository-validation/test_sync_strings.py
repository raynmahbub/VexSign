#!/usr/bin/env python3
"""Regression tests for the localisation catalogue helpers in VexSign/Tools/sync-strings.py.

The important guarantee is conservative pruning: a key Xcode marked `stale` but
that still appears as a literal in the app (for example inside `Text("…")`, which
`collect()` does not see) must never be removed.
"""

import importlib.util
import json
import re
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
SPEC = importlib.util.spec_from_file_location("sync_strings", ROOT / "VexSign/Tools/Validation/repository-validation/sync-strings.py")
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


class PluralCoverageTests(unittest.TestCase):
    """A count with no plural form reads "1 items" in English and is wrong in most languages."""

    @staticmethod
    def catalogue(*values):
        return {"strings": {
            value: {"localizations": {"en": {"stringUnit": {"state": "translated", "value": value}}}}
            for value in values
        }}

    @staticmethod
    def pluralised(value, one, other):
        return {"localizations": {"en": {"variations": {"plural": {
            "one": {"stringUnit": {"state": "translated", "value": one}},
            "other": {"stringUnit": {"state": "translated", "value": other}},
        }}}}}

    def test_countable_english_without_variations_is_a_gap(self):
        data = self.catalogue("%lld items", "Added %lld files", "Deleted %lld items")
        self.assertEqual(sync.plural_gaps(data), ["%lld items", "Added %lld files", "Deleted %lld items"])

    def test_variations_close_the_gap(self):
        data = {"strings": {"%lld items": self.pluralised("%lld items", "%lld item", "%lld items")}}
        self.assertEqual(sync.plural_gaps(data), [])

    def test_a_verb_follower_is_not_a_plural_noun(self):
        # "%lld items need review" is a sentence, not a noun phrase; demanding the
        # mechanical rewrite the rule cannot produce would be a false failure.
        data = self.catalogue("%lld ms", "Load command %lld points at a name outside itself.")
        self.assertEqual(sync.plural_gaps(data), [])

    def test_two_counts_in_one_sentence_are_left_to_a_translator(self):
        data = self.catalogue("%lld updates · %lld signed · %lld queued · %lld skipped")
        self.assertEqual(sync.plural_gaps(data), [])

    def test_existing_catalogue_has_no_gaps(self):
        self.assertEqual(sync.plural_gaps(sync.catalog()), [])


class LiteralCollectionTests(unittest.TestCase):
    def test_foundation_localization_and_legacy_calls_share_catalog_keys(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory)
            (source / "UseCase.swift").write_text(
                'NSLocalizedString("Importing…", comment: "")\n'
                'String(format: NSLocalizedString("Added %lld tweaks", comment: ""), arguments: [2])\n'
                'String.localized("Importing…")\n'
                '.localized("Escaped \\\"quote\\\"")\n'
                'NSLocalizedString("Dynamic \\(value)", comment: "")\n',
                encoding="utf-8",
            )
            previous = sync.ROOT, sync.SOURCE_ROOT
            try:
                sync.ROOT = source
                sync.SOURCE_ROOT = source
                keys, dynamic, scanned = sync.collect()
            finally:
                sync.ROOT, sync.SOURCE_ROOT = previous
            self.assertEqual(scanned, 1)
            self.assertEqual(set(keys), {"Importing…", "Added %lld tweaks", 'Escaped "quote"'})
            self.assertEqual(len(dynamic), 1)
            self.assertEqual(keys["Importing…"], ["UseCase.swift"])


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

    def test_the_tree_carries_no_prunable_stale_key(self):
        """Nothing else stopped dead keys accumulating in twelve locales at once.

        `--prune-stale` never removes a key that still appears as a literal, so a key it
        would remove is dead weight in the catalogue and in every translation of it. Run the
        prune when this fails; the diff is deletions only.
        """
        removable = sync.stale_absent_keys(sync.catalog(), sync.source_blob())
        self.assertEqual(
            removable,
            [],
            "stale catalogue keys no source string uses: run "
            "`python3 VexSign/Tools/Validation/repository-validation/sync-strings.py --prune-stale`",
        )

    def test_catalogue_formatting_round_trips(self):
        raw = sync.CATALOGUE.read_text(encoding="utf-8")
        rendered = json.dumps(json.loads(raw), indent=2, ensure_ascii=False, separators=(",", " : ")) + "\n"
        self.assertEqual(raw, rendered)


class PlaceholderConsistencyTests(unittest.TestCase):
    """A translation must consume exactly the arguments its key was written for.

    `String.localized(_:arguments:)` is `String(format:)`: a `%@` where the key
    says `%lld` is a crash on that locale, and a dropped specifier is a sentence
    that silently loses its number.
    """

    @staticmethod
    def catalogue(key, **translations):
        units = {
            language: {"stringUnit": {"state": "translated", "value": value}}
            for language, value in translations.items()
        }
        return {"sourceLanguage": "en", "strings": {key: {"localizations": units}}}

    def test_matching_specifiers_are_not_a_gap(self):
        data = self.catalogue("%@: %lld added", de="%1$@: %2$lld hinzugefügt")
        self.assertEqual(sync.placeholder_gaps(data), [])

    def test_reordered_positional_specifiers_are_equivalent(self):
        data = self.catalogue("%@ added %lld", fr="%2$lld ajoutés par %1$@")
        self.assertEqual(sync.placeholder_gaps(data), [])

    def test_dropped_specifier_is_a_gap(self):
        data = self.catalogue("%@: %lld added", it="%1$@ aggiunti")
        gaps = sync.placeholder_gaps(data)
        self.assertEqual(len(gaps), 1)
        self.assertEqual(gaps[0][1], "it")

    def test_changed_conversion_is_a_gap(self):
        # %d prints the wrong value for an Int and truncates above 2^31; %@ on an
        # Int is an outright crash.
        data = self.catalogue("Added %lld files", es="Añadidos %@ archivos")
        self.assertEqual(len(sync.placeholder_gaps(data)), 1)

    def test_plural_forms_are_checked(self):
        data = {
            "sourceLanguage": "en",
            "strings": {
                "%lld items": {
                    "localizations": {
                        "en": {"variations": {"plural": {
                            "one": {"stringUnit": {"value": "%lld item"}},
                            "other": {"stringUnit": {"value": "%lld items"}},
                        }}},
                        "ru": {"variations": {"plural": {
                            "one": {"stringUnit": {"value": "%@ элемент"}},
                            "other": {"stringUnit": {"value": "%lld элементов"}},
                        }}},
                    }
                }
            },
        }
        gaps = sync.placeholder_gaps(data)
        self.assertEqual([(gap[1], gap[2]) for gap in gaps], [("ru", "plural.one")])

    def test_literal_percent_is_not_an_argument(self):
        data = self.catalogue("100%% sure: %lld", de="100%% sicher: %lld")
        self.assertEqual(sync.placeholder_gaps(data), [])

    def test_source_language_is_not_compared_with_itself(self):
        data = self.catalogue("%lld files", en="%lld file(s)")
        self.assertEqual(sync.placeholder_gaps(data), [])


if __name__ == "__main__":
    unittest.main()


#: A string handed to a UI boundary instead of to `.localized` never reaches the catalogue:
#: `collect()` only sees `.localized("…")`, so `--check` stays green while the dialog stays
#: English in all twelve locales. These are the two boundaries where that happened.
BARE_USER_FACING = (
    ("showUIErrorMessage(title:)", re.compile(r"showUIErrorMessage\([^)]*?title:\s*\"[^\"]*\"\s*[,)\n]")),
    ("sendCompletionNotification(status:)", re.compile(r"sendCompletionNotification\([^)]*?status:\s*\"[^\"]*\"\s*[,)\n]")),
)


def bare_user_facing_literals(text):
    """Line numbers of titles/statuses passed as a bare literal rather than `.localized(…)`.

    A literal that is concatenated (``status: "❌ " + .localized(…)``) does not match: the
    character after the closing quote is not ``,``, ``)`` or a newline.
    """
    found = []
    for label, pattern in BARE_USER_FACING:
        for match in pattern.finditer(text):
            found.append((text.count("\n", 0, match.start()) + 1, label))
    return sorted(found)


class UserFacingLiteralTests(unittest.TestCase):
    """A dialog title has to come from the catalogue, like every other sentence in the app."""

    def test_a_bare_title_is_reported(self):
        sample = '\t\tself.errorDelegate?.showUIErrorMessage(title: "Import Failed", message: "x")\n'
        self.assertEqual(bare_user_facing_literals(sample), [(1, "showUIErrorMessage(title:)")])

    def test_a_bare_status_is_reported(self):
        sample = 'sendCompletionNotification(for: download, status: "❌ Download failed")\n'
        self.assertEqual(bare_user_facing_literals(sample), [(1, "sendCompletionNotification(status:)")])

    def test_a_localized_title_is_accepted(self):
        sample = 'showUIErrorMessage(title: .localized("Import failed"), message: message)\n'
        self.assertEqual(bare_user_facing_literals(sample), [])

    def test_a_concatenated_status_is_accepted(self):
        sample = 'sendCompletionNotification(for: download, status: "❌ " + .localized("Download failed"))\n'
        self.assertEqual(bare_user_facing_literals(sample), [])

    def test_the_tree_passes_titles_through_the_catalogue(self):
        offences = []
        for path in sorted(sync.SOURCE_ROOT.rglob("*.swift")):
            text = path.read_text(encoding="utf-8", errors="ignore")
            for line, label in bare_user_facing_literals(text):
                offences.append(f"{path.relative_to(sync.ROOT).as_posix()}:{line} {label}")
        self.assertEqual(
            offences,
            [],
            "these user-facing strings skip .localized(…) and so stay English in every locale",
        )
