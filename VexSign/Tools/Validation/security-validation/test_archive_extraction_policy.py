#!/usr/bin/env python3
"""Regression guard: every archive is validated immediately before it is extracted.

`ArchiveSafetyValidator` already rejects traversal, symlinks, duplicates (including
case-only and Unicode-normalization-only differences) and file/directory conflicts.
That guarantee only holds for routes that call it. A new extraction call in a future
change would bypass every one of those rules without touching the validator, so
this test drives the rule instead: the call that writes files has to be preceded,
in the same function, by a validation of the same archive.

The retired `marmelroy/Zip` backend is still matched here on purpose: if it is ever
reintroduced, its calls have to obey the same rule.

Two extraction entry points are distinguished:

  * raw ones (`Zip.unzipFile`, `Archive(url:)`, `archive.extract(entry:)`) must be
    preceded by `ArchiveSafetyValidator.validate` in the same function;
  * `IPAExtractor.extract` is the validating wrapper — it calls the validator before
    it opens the archive and re-checks containment before every write. Routes are
    expected to use it, so its call sites are counted: renaming or deleting one, or
    quietly opening an archive directly instead, fails the last test here. That check
    is what was missing when the retired Zip backend silently left the scan matching
    a single unrelated call site.

    python3 VexSign/Tools/Validation/security-validation/test_archive_extraction_policy.py
"""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[4]
SOURCES = ROOT / "VexSign/App/iOS"
VALIDATOR = SOURCES / "Security/Archives/ArchiveSafetyValidator.swift"

# The calls that write an untrusted archive to disk.
EXTRACTORS = (
    re.compile(r"\bZip\.unzipFile\("),
    re.compile(r"\barchive\.extract\("),
    # ZIPFoundation's own initialiser: opening the archive is the step before its
    # entries can be written, so it belongs in the same rule as the writers.
    re.compile(r"\bArchive\(url:"),
)

#: The wrapper that validates on every caller's behalf (see the module docstring).
VALIDATING_EXTRACTOR = re.compile(r"\bIPAExtractor\.extract\(")
#: Included, backup restore, certificate import, tweak import and the signing import path.
EXPECTED_VALIDATING_CALL_SITES = 5

FUNC = re.compile(r"^\s*(?:private |public |internal |static |func )*func\s+(\w+)\s*\(", re.MULTILINE)


def _functions(text: str):
    """(name, body) for each func, using indentation-free brace matching on `func`."""
    for match in FUNC.finditer(text):
        start = text.find("{", match.end())
        if start == -1:
            continue
        depth = 0
        for index in range(start, len(text)):
            character = text[index]
            if character == "{":
                depth += 1
            elif character == "}":
                depth -= 1
                if depth == 0:
                    yield match.group(1), text[match.start():index + 1]
                    break


class ArchiveExtractionPolicyTests(unittest.TestCase):
    def test_the_validator_still_covers_the_documented_attack_classes(self):
        source = VALIDATOR.read_text()
        # Case names carry a payload except the two count/limit rules.
        for rule in ("absolutePath", "traversalPath", "symbolicLink", "duplicateEntry", "pathTypeConflict"):
            self.assertIn(f"case {rule}(", source[:4000], f"the validator lost its {rule} rule")
        for rule in ("tooManyEntries", "tooLarge"):
            self.assertIn(f"case {rule}", source[:4000], f"the validator lost its {rule} rule")
        self.assertIn("precomposedStringWithCanonicalMapping", source,
                      "Unicode-normalization collisions must keep folding to one identity")

    def test_every_extraction_is_preceded_by_validation_in_the_same_function(self):
        unguarded = []
        for path in sorted(SOURCES.rglob("*.swift")):
            if path == VALIDATOR:
                # This file *is* the check; its own `Archive(url:)` is the archive being
                # validated, so requiring it to validate itself is circular.
                continue
            text = path.read_text(encoding="utf-8")
            if not any(pattern.search(text) for pattern in EXTRACTORS):
                continue
            for name, body in _functions(text):
                if not any(pattern.search(body) for pattern in EXTRACTORS):
                    continue
                if "ArchiveSafetyValidator.validate(" not in body:
                    unguarded.append(f"{path.relative_to(ROOT)}: {name}() extracts without validating")
        self.assertEqual(unguarded, [],
                         "call ArchiveSafetyValidator.validate(_:destination:) first:\n  "
                         + "\n  ".join(unguarded))

    def test_the_validating_wrapper_still_owns_the_extraction_routes(self):
        """Every route extracts through `IPAExtractor`, and that one validates first.

        Counting the call sites is the part that rots: when the retired Zip package was
        removed, nothing noticed that the scan had stopped matching the real routes.
        """
        sites = []
        for path in sorted(SOURCES.rglob("*.swift")):
            for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
                if VALIDATING_EXTRACTOR.search(line):
                    sites.append(f"{path.relative_to(ROOT)}:{number}")
        self.assertGreaterEqual(
            len(sites),
            EXPECTED_VALIDATING_CALL_SITES,
            "an extraction route stopped using IPAExtractor.extract, so nothing checks it "
            "before it writes:\n  " + "\n  ".join(sites),
        )

        wrapper = (SOURCES / "Infrastructure/Archives/Extraction/IPAExtractor.swift").read_text()
        self.assertLess(
            wrapper.index("ArchiveSafetyValidator.validate("),
            wrapper.index("Archive(url:"),
            "the wrapper must validate before it opens the archive",
        )

    def test_the_guard_would_catch_an_unvalidated_extraction(self):
        fixture = """
        func unzip(_ archive: URL, to destination: URL) async throws {
            try await withCheckedThrowingContinuation { continuation in
                try Zip.unzipFile(archive, destination: destination)
            }
        }
        func safe(_ archive: URL, to destination: URL) async throws {
            try ArchiveSafetyValidator.validate(archive, destination: destination)
            try Zip.unzipFile(archive, destination: destination)
        }
        func peek(_ url: URL) throws -> Archive {
            try Archive(url: url, accessMode: .read)
        }
        """
        findings = []
        for name, body in _functions(fixture):
            if any(pattern.search(body) for pattern in EXTRACTORS):
                if "ArchiveSafetyValidator.validate(" not in body:
                    findings.append(name)
        self.assertEqual(sorted(findings), ["peek", "unzip"])

    def test_the_streaming_extractor_rechecks_containment_before_each_write(self):
        # A one-time pass is not enough: the destination is mutable while an extraction
        # runs, so IPAExtractor re-validates inside its entry loop.
        source = (SOURCES / "Infrastructure/Archives/Extraction/IPAExtractor.swift").read_text()
        loop = source.split("for entry in archive", 1)[1]
        self.assertLess(loop.index("validateDestination"), loop.index("FileHandle(forWritingTo:"),
                        "the per-entry containment check must run before the write")

    def test_the_retired_zip_package_stays_retired(self):
        # It was linked into the app target while nothing imported it: an unmaintained
        # C/Objective-C zip reader in the shipping binary. Extraction uses
        # ZIPFoundation and SWCompression; this keeps the dead dependency from returning.
        project = (ROOT / "VexSign.xcodeproj/project.pbxproj").read_text()
        self.assertNotIn("marmelroy/Zip", project)
        for path in sorted((ROOT / "VexSign/App").rglob("*.swift")):
            self.assertNotIn("import Zip\n", path.read_text(encoding="utf-8"),
                             f"{path.relative_to(ROOT)} reintroduced the retired Zip package")

    def test_no_extraction_route_silently_skips_a_validation_error(self):
        """`try? validate` would turn every rule above into a no-op."""
        for path in sorted(SOURCES.rglob("*.swift")):
            text = path.read_text(encoding="utf-8")
            self.assertNotIn("try? ArchiveSafetyValidator.validate", text,
                             f"{path.relative_to(ROOT)} discards a validation failure")


if __name__ == "__main__":
    unittest.main(verbosity=2)
