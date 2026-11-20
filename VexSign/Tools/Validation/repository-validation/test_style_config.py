#!/usr/bin/env python3
"""Regression tests for the Swift style configuration agreeing with itself (offline, no third-party deps).

Two configs describe Swift indentation and they contradicted each other: `.editorconfig` said
`indent_style = tab` for every file including Swift, while `.swiftformat` — which is what
`make format` actually runs — said `usetabs false`. Editors followed the first, the formatter the
second, and the tree ended up with 268 tab-indented first-party Swift files, 490 space-indented
and 167 mixing both in a single file. Nothing surfaced it because no validator read either file
and the CI format step is report-only (`continue-on-error: true`).

`.swiftlint.yml` rots the way a stale Dependabot `directory` does: a path that no longer exists is
ignored rather than reported, so a first-party package can fall out of lint scope unnoticed. That
happened to `Packages/NativeSigning` — the Apple-account, PKCS#12/CMS and provisioning-profile
code, the most security-sensitive Swift in the repository — and to the embedded-container host
overlay, which was in neither `included` nor `excluded`.

These tests pin the agreements so the drift cannot come back quietly. The YAML lists are parsed by
hand to keep this dependency-free like the rest of the suite.
"""
from __future__ import annotations

import fnmatch
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
EDITORCONFIG = ROOT / ".editorconfig"
SWIFTFORMAT = ROOT / ".swiftformat"
SWIFTLINT = ROOT / ".swiftlint.yml"

#: Upstream sources committed into the tree. Their formatting belongs to upstream: rewriting them
#: turns the next re-vendor into a wall of whitespace noise instead of a real diff. Both tools must
#: leave them alone, and they are the only Swift the lint-scope test is allowed to skip as excluded.
VENDORED = ("VexSign/Packages/Vendor", "VexSign/Packages/SideSign")


def editorconfig_sections(path=EDITORCONFIG):
    """Returns [(glob, {key: value})] for each section, in file order."""
    sections = []
    current = None
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if line.startswith("[") and line.endswith("]"):
            current = (line[1:-1], {})
            sections.append(current)
            continue
        if current is not None and "=" in line:
            key, _, value = line.partition("=")
            current[1][key.strip()] = value.strip()
    return sections


def swiftformat_flags(path=SWIFTFORMAT):
    """Returns {option: value} from swiftformat's `key value` lines."""
    flags = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        key, _, value = line.partition(" ")
        flags[key.strip()] = value.strip()
    return flags


def swiftformat_excludes(path=SWIFTFORMAT):
    """Returns the comma-separated `exclude` list as path fragments."""
    value = swiftformat_flags(path).get("exclude", "")
    return [part.strip() for part in value.split(",") if part.strip()]


def swiftlint_list(key, path=SWIFTLINT):
    """Returns the entries of one top-level YAML list, unquoted and comment-free."""
    entries = []
    inside = False
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0].rstrip()
        if re.match(rf"^{key}:\s*$", line):
            inside = True
            continue
        if inside:
            if not line.strip().startswith("- "):
                # A non-indented key ends the list; so does the next top-level key.
                if line and not line.startswith(" "):
                    break
                continue
            entries.append(line.strip()[2:].strip().strip("\"'"))
    return entries


def _matches(rel: str, pattern: str) -> bool:
    """Whether a repo-relative path falls under one excluded/included pattern."""
    if pattern.startswith("**/"):
        tail = pattern[3:]
        # `**/Package.swift` matches the file at any depth; `**/.build` any directory component.
        return rel == tail or rel.endswith("/" + tail) or tail in rel.split("/")
    return rel == pattern or rel.startswith(pattern + "/") or fnmatch.fnmatch(rel, pattern)


def first_party_swift():
    """Every committed .swift path, repo-relative."""
    return sorted(
        p.relative_to(ROOT).as_posix()
        for p in ROOT.rglob("*.swift")
        if ".git" not in p.parts
    )


class SwiftIndentationAgreementTests(unittest.TestCase):
    def test_editorconfig_agrees_with_the_formatter_on_swift_indentation(self):
        flags = swiftformat_flags()
        self.assertIn("usetabs", flags, ".swiftformat must keep declaring usetabs")
        swift = dict(editorconfig_sections()).get("*.swift")
        self.assertIsNotNone(swift, ".editorconfig has no [*.swift] section, so [*] decides Swift")

        # `usetabs false` is what `make format` writes, so that is the side the editor must match.
        expected = "space" if flags["usetabs"].lower() == "false" else "tab"
        self.assertEqual(swift.get("indent_style"), expected)

    def test_editorconfig_agrees_with_the_formatter_on_swift_indent_width(self):
        flags = swiftformat_flags()
        swift = dict(editorconfig_sections()).get("*.swift")
        self.assertIsNotNone(swift)
        self.assertEqual(swift.get("indent_size"), flags.get("indent"))

    def test_star_section_does_not_leak_tabs_into_swift(self):
        # The bare [*] section is tabs; without an explicit [*.swift] override Swift would inherit
        # it, which is the contradiction this file exists to prevent.
        star = dict(editorconfig_sections()).get("*", {})
        swift = dict(editorconfig_sections()).get("*.swift")
        if star.get("indent_style") == "tab":
            self.assertIsNotNone(swift, "[*] sets tabs, so [*.swift] must override it")
            self.assertEqual(swift.get("indent_style"), "space")


class SwiftLintScopeTests(unittest.TestCase):
    def test_every_included_path_exists(self):
        # A stale entry here is silently ignored by SwiftLint, exactly like a stale Dependabot
        # `directory`: the scope shrinks and nothing reports it.
        included = swiftlint_list("included")
        self.assertTrue(included, "no `included:` entries parsed")
        missing = [entry for entry in included if not (ROOT / entry).exists()]
        self.assertEqual([], missing, "swiftlint `included:` paths that do not exist")

    def test_no_first_party_swift_file_is_outside_lint_scope(self):
        included = swiftlint_list("included")
        excluded = swiftlint_list("excluded")

        uncovered = []
        for rel in first_party_swift():
            if any(_matches(rel, pattern) for pattern in excluded):
                continue
            if not any(rel == root or rel.startswith(root + "/") for root in included):
                uncovered.append(rel)

        self.assertEqual(
            [],
            uncovered,
            "first-party Swift outside `included:` (and not excluded), so SwiftLint never reads it",
        )

    def test_vendored_swift_is_excluded_not_just_unlisted(self):
        excluded = swiftlint_list("excluded")
        for root in VENDORED:
            self.assertIn(root, excluded, f"{root} is vendored upstream source and must be excluded")
            self.assertTrue((ROOT / root).exists(), f"{root} no longer exists; update VENDORED")


class SwiftFormatScopeTests(unittest.TestCase):
    def test_vendored_swift_is_excluded_by_the_formatter_too(self):
        # `make format FIX=1` runs over everything not excluded here, so a vendored package missing
        # from this list gets rewritten in place even though SwiftLint was told to leave it alone.
        excludes = swiftformat_excludes()
        for root in VENDORED:
            self.assertIn(root, excludes, f"{root} must be excluded from swiftformat as well")

    def test_formatter_and_linter_agree_on_what_is_vendored(self):
        excludes = set(swiftformat_excludes())
        excluded = set(swiftlint_list("excluded"))
        for root in VENDORED:
            self.assertIn(root, excludes)
            self.assertIn(root, excluded)


if __name__ == "__main__":
    unittest.main()
