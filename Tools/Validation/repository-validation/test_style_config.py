#!/usr/bin/env python3
"""Regression tests for the Swift style configuration agreeing with itself (offline, no third-party deps).

Two configs describe Swift indentation and they contradicted each other: `.editorconfig` said
`indent_style = tab` for every file including Swift, while `.swiftformat` — which is what
`make format` actually runs — said `usetabs false`. Editors followed the first, the formatter the
second, and the tree ended up with 268 tab-indented first-party Swift files, 490 space-indented
and 167 mixing both in a single file. Nothing surfaced it because no validator read either file
and the CI format step is report-only (`continue-on-error: true`).

Worse, that formatter had never run at all. `.swiftformat` had drifted away from the version
ci.yml pins (0.64.6): ten options (`usetabs`, the whole `space*` family, `braces`, `elsebalance`)
and thirteen rules (`unusedImport`, `unusedVariable`, `trimWhitespace`, `wrapFunctionCalls`,
`wrapTernary` and more) no longer exist in it, and swiftformat treats an unknown name as a hard
error, not a warning. Every `make format` and every CI lint therefore aborted on the first stale
key having formatted nothing, and `continue-on-error: true` kept that abort out of sight. The
rules list also omitted `indent`, so even a loadable config could not have converted a single
tab-indented file. `SwiftFormatLoadabilityTests` pins the repair.

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

ROOT = Path(__file__).resolve().parents[3]
EDITORCONFIG = ROOT / ".editorconfig"
SWIFTFORMAT = ROOT / ".swiftformat"
SWIFTLINT = ROOT / ".swiftlint.yml"

#: Upstream sources committed into the tree. Their formatting belongs to upstream: rewriting them
#: turns the next re-vendor into a wall of whitespace noise instead of a real diff. Both tools must
#: leave them alone, and they are the only Swift the lint-scope test is allowed to skip as excluded.
VENDORED = ("Packages/Vendor", "Packages/SideSign")


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
        # swiftformat 0.64.x has no `usetabs` option: `indent` takes a space count or the
        # word `tab`, and `useTabs` is derived from that. Asserting `usetabs` here is what
        # let .swiftformat keep declaring an option the pinned formatter rejects outright,
        # so this test used to pin the bug instead of catching it.
        self.assertIn("indent", flags, ".swiftformat must keep declaring indent")
        self.assertNotIn(
            "usetabs", flags,
            "usetabs is not an option in swiftformat 0.64.x; `indent 4` is what selects spaces",
        )
        swift = dict(editorconfig_sections()).get("*.swift")
        self.assertIsNotNone(swift, ".editorconfig has no [*.swift] section, so [*] decides Swift")

        # `indent 4` is what `make format` writes, so that is the side the editor must match.
        expected = "tab" if flags["indent"].strip().lower() in ("tab", "tabs") else "space"
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


class SwiftFormatLoadabilityTests(unittest.TestCase):
    """The pinned formatter must accept every name .swiftformat declares.

    swiftformat 0.64.6 -- the version ci.yml builds -- treats an unknown option or rule as a hard
    error and then formats nothing, so a single stale name silently disabled `make format` for the
    whole repository while the report-only CI lint printed that error into a log nobody read. The
    names below are the ones that had gone stale. This is a regression pin, not a validator: it
    cannot know what a future swiftformat renames. check-swift-format-drift.py probes the file
    against the real binary in CI whenever .swiftformat changes, which is the half that can.
    """

    REMOVED_OPTIONS = {
        "usetabs", "braces", "elsebalance", "spacearoundoperators", "spacearoundbrackets",
        "spacearoundbraces", "spacearoundrangeoperators", "spaceinsidebrackets",
        "spaceinsideparens", "spaceinsidebraces",
    }
    REMOVED_RULES = {
        "redundantoptionalinit", "redundantprotocol", "unusedimport", "unusedprivatedeclaration",
        "unusedvariable", "trimwhitespace", "prefernimbleoperator", "preferselftype",
        "specifiedselftype", "wrapternary", "wrapcollections", "wrapfunctioncalls",
        "wrapfunctiondefinitions",
    }

    def rules(self):
        return {name.strip() for name in swiftformat_flags().get("rules", "").split(",") if name.strip()}

    def test_no_option_the_pinned_formatter_rejects(self):
        declared = {key.strip().lower() for key in swiftformat_flags()}
        self.assertEqual(self.REMOVED_OPTIONS & declared, set())

    def test_no_rule_the_pinned_formatter_rejects(self):
        self.assertEqual(self.REMOVED_RULES & {name.lower() for name in self.rules()}, set())

    def test_the_indent_rule_is_enabled_or_nothing_can_fix_indentation(self):
        # `rules` is an allowlist, so with `indent` absent the formatter leaves every tab-indented
        # file exactly as it is and the one-time pass the CI report exists to announce cannot run.
        self.assertIn("indent", self.rules())

    def test_unused_private_declarations_uses_the_real_plural_name(self):
        self.assertIn("unusedPrivateDeclarations", self.rules())

    def test_trailing_commas_follow_the_tree_not_the_tool_default(self):
        # 0.64.6 defaults `--trailing-commas` to `always`, but the tree closes 24815 multi-line
        # items without a trailing comma against 21 with one, so the default would have demanded a
        # rewrite of nearly every list in the repository.
        self.assertEqual(swiftformat_flags().get("trailingcommas"), "never")

    def test_explicit_self_is_not_imposed_on_a_bare_member_access_tree(self):
        # `self insert` adds explicit self everywhere; only 310 of 937 first-party Swift files
        # mention self at all, and mostly where Swift requires it. That is a tree-wide rewrite
        # nobody asked for, so the config says `remove`.
        self.assertNotEqual(swiftformat_flags().get("self", "").strip().lower(), "insert")

    def test_case_and_ifdef_indentation_follow_the_tree(self):
        # 701 switch statements keep `case` level with `switch` against 4 that indent it, and
        # 18 `#if` bodies are level with the directive against 1 indented, so the previous
        # `indentcase true` / `ifdef indent` described a style this repository does not write.
        flags = swiftformat_flags()
        self.assertEqual(flags.get("indentcase"), "false")
        self.assertEqual(flags.get("ifdef"), "no-indent")

    def test_the_spacing_intentions_survived_as_rules(self):
        # The removed `space*` options were not dropped on the floor: 0.64.6 expresses the same
        # intentions as rules, and each one matches what the tree already writes.
        for rule in ("spaceAroundOperators", "spaceInsideParens", "spaceInsideBraces", "braces"):
            self.assertIn(rule, self.rules(), f"{rule} replaces a removed spacing option")


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


class GitAttributesTests(unittest.TestCase):
    """`.gitattributes` must agree with `.editorconfig`, not fight it."""

    def test_line_endings_are_lf(self):
        path = ROOT / ".gitattributes"
        self.assertTrue(path.is_file(), "the root architecture lists .gitattributes")
        text = path.read_text(encoding="utf-8")
        self.assertIn("* text=auto eol=lf", text)
        self.assertNotIn("eol=crlf", text)

    def test_signing_and_asset_binaries_are_never_rewritten(self):
        text = (ROOT / ".gitattributes").read_text(encoding="utf-8")
        for pattern in ("*.png", "*.p12", "*.mobileprovision", "*.ipa"):
            self.assertRegex(text, rf"(?m)^{re.escape(pattern)} binary$", pattern)


if __name__ == "__main__":
    unittest.main()
