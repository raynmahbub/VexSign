#!/usr/bin/env python3
"""Regression checks for the Swift style-drift gate (offline; swiftformat not required).

The gate is only worth running if it fails on the lines a change owns and stays
quiet about the backlog it inherits, so every case here pins one half of that
contract. The fixtures are real shapes rather than invented ones: the hunk headers
come from this repository's own `git diff -U0` output, including the
pure-deletion `+N,0` form that owns no line, and the report fixture is
SwiftFormat's JSON schema as its own CommandLineTests assert it (pretty-printed,
`"rule_id" : "emptyBraces"`).

Nothing here executes the formatter. The point is that the attribution logic --
which lines a diff owns, which paths are vendored and out of scope, whether a
report can be trusted -- is decided in Python that can be tested anywhere, so the
CI step is only wiring around it.
"""
from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[3]
VALIDATION = ROOT / "Tools/Validation/repository-validation"
WORKFLOWS = ROOT / ".github/workflows"

BASE = "294c8cfd7f64d2742bd18ed1f0a38147d2505541"


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, VALIDATION / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# The gate under test, plus test_style_config for the .swiftformat reading it
# already owns: the gate must agree with the config that suite pins rather than
# carry a second opinion about what is vendored.
drift = load("swift_format_drift", "check-swift-format-drift.py")
style = load("style_config", "test_style_config.py")


def real_excludes():
    return drift.load_excludes((ROOT / ".swiftformat").read_text(encoding="utf-8"))


def step_block(workflow_text, step_name):
    """Returns the lines of one `- name:` step, up to the next step or job."""
    lines = workflow_text.splitlines()
    start = None
    for index, line in enumerate(lines):
        if line.strip() == f"- name: {step_name}":
            start = index
            break
    if start is None:
        return None
    indent = len(lines[start]) - len(lines[start].lstrip())
    body = [lines[start]]
    for line in lines[start + 1:]:
        if not line.strip():
            body.append(line)
            continue
        if len(line) - len(line.lstrip()) <= indent and line.strip().startswith("- "):
            break
        body.append(line)
    return "\n".join(body)


class ChangedLineOwnershipTests(unittest.TestCase):
    def test_pure_deletion_owns_no_line(self):
        # Real header from this repository: seven old lines removed, none written,
        # so no violation can be attributed to it and the gate stays quiet.
        patch = "@@ -202,7 +224,0 @@ enum CertificateManagementService {"
        self.assertEqual(drift.changed_line_ranges(patch), set())

    def test_single_line_hunk_without_counts_owns_one_line(self):
        # git omits a count of one, so `+223` means exactly line 223.
        patch = "@@ -200 +223 @@ enum CertificateManagementService {"
        self.assertEqual(drift.changed_line_ranges(patch), {223})

    def test_insertion_hunk_owns_its_whole_range(self):
        patch = "@@ -292,0 +293,61 @@ final class TemporaryCleanupPolicyTests: XCTestCase {"
        self.assertEqual(drift.changed_line_ranges(patch), set(range(293, 354)))

    def test_several_hunks_union_and_trailing_context_is_ignored(self):
        patch = (
            "@@ -10,0 +11,2 @@ struct Foo {\n"
            "+    let a = 1\n"
            "+    let b = 2\n"
            "@@ -40,3 +42 @@ struct Foo {\n"
            "-    let old = 1\n"
            "+    let new = 1\n"
        )
        self.assertEqual(drift.changed_line_ranges(patch), {11, 12, 42})

    def test_a_diff_with_no_hunks_owns_nothing(self):
        self.assertEqual(drift.changed_line_ranges(""), set())
        self.assertEqual(drift.changed_line_ranges("diff --git a/x.swift b/x.swift\n"), set())


class ReportParsingTests(unittest.TestCase):
    # Pretty-printed the way JSONEncoder emits it, with real rule names.
    REPORT = """[
  {
    "file" : "VexSign/Features/Dashboard/Home/Views/AppStoreView.swift",
    "line" : 14,
    "reason" : "Replace tabs with spaces",
    "rule_id" : "indent"
  },
  {
    "file" : "VexSignTests/UnitTests/Persistence/CleanupOperationGuardTests.swift",
    "line" : 293,
    "reason" : "Remove trailing whitespace",
    "rule_id" : "trailingSpace"
  }
]"""

    def test_parses_the_formatter_schema(self):
        violations = drift.parse_report(self.REPORT)
        self.assertEqual(len(violations), 2)
        self.assertEqual(
            violations[0],
            drift.Violation(
                "VexSign/Features/Dashboard/Home/Views/AppStoreView.swift",
                14,
                "indent",
                "Replace tabs with spaces",
            ),
        )
        self.assertEqual(violations[1].line, 293)
        self.assertEqual(violations[1].rule, "trailingSpace")

    def test_empty_report_is_clean_not_an_error(self):
        self.assertEqual(drift.parse_report("[]"), [])
        self.assertEqual(drift.parse_report("   \n"), [])

    def test_unparsable_report_is_refused_not_read_as_empty(self):
        # Console text where JSON was expected must raise: returning no violations
        # here would make the gate pass every pull request it failed to read.
        for text in ("swiftformat: unknown option --reporter", "[{\"line\": 1}", "not json"):
            with self.assertRaises(ValueError, msg=text):
                drift.parse_report(text)

    def test_report_that_is_not_a_list_is_refused(self):
        with self.assertRaises(ValueError):
            drift.parse_report('{"file": "x.swift", "line": 1}')

    def test_entry_without_an_integer_line_is_refused(self):
        with self.assertRaises(ValueError):
            drift.parse_report(json.dumps([{"file": "x.swift", "line": "14", "rule_id": "indent"}]))

    def test_absolute_and_prefixed_paths_normalise_to_the_repository_root(self):
        report = json.dumps(
            [{"file": str(ROOT / "VexSign/App/Foo.swift"), "line": 3, "reason": "r", "rule_id": "indent"}]
        )
        self.assertEqual(drift.parse_report(report)[0].path, "VexSign/App/Foo.swift")
        relative = json.dumps([{"file": "./VexSign/App/Bar.swift", "line": 3, "reason": "r", "rule_id": "indent"}])
        self.assertEqual(drift.parse_report(relative)[0].path, "VexSign/App/Bar.swift")

    def test_unattributable_entry_is_dropped_not_guessed(self):
        report = json.dumps([{"file": None, "line": 3, "reason": "r", "rule_id": "indent"}])
        self.assertEqual(drift.parse_report(report), [])


class AttributionTests(unittest.TestCase):
    def violation(self, path, line):
        return drift.Violation(path, line, "indent", "Replace tabs with spaces")

    def test_added_file_is_owned_outright(self):
        found = drift.attribute([self.violation("VexSign/App/New.swift", 1)], {"VexSign/App/New.swift"}, {})
        self.assertEqual([violation.line for violation in found], [1])

    def test_modified_file_gates_only_the_lines_it_changed(self):
        path = "VexSign/App/Old.swift"
        violations = [self.violation(path, 12), self.violation(path, 400)]
        found = drift.attribute(violations, set(), {path: {400}})
        self.assertEqual(
            [violation.line for violation in found], [400],
            "line 12 is inherited backlog; failing a change for it is what keeps "
            "the whole-tree lint report-only",
        )

    def test_violation_in_an_untouched_file_is_not_gated(self):
        self.assertEqual(drift.attribute([self.violation("VexSign/App/Other.swift", 5)], set(), {}), [])

    def test_no_violations_is_clean(self):
        self.assertEqual(drift.attribute([], {"VexSign/App/New.swift"}, {}), [])


class VendoredScopeTests(unittest.TestCase):
    def test_gate_reads_the_same_excludes_the_style_suite_pins(self):
        # Two copies of the exclude list would drift apart, and the vendored trees
        # are exactly the ones that must never be reformatted in place.
        self.assertEqual(real_excludes(), style.swiftformat_excludes())

    def test_vendored_swift_is_out_of_scope(self):
        excludes = real_excludes()
        for root in style.VENDORED:
            self.assertTrue(drift.is_excluded(f"{root}/Sources/Anything.swift", excludes), root)
        # Hash-pinned by NativeSigning/inputs.lock.json: a reformat here would break
        # the privacy overlay contract, not just the vendoring fidelity.
        self.assertTrue(drift.is_excluded("Packages/SideSign/Sources/Logging.swift", excludes))

    def test_first_party_swift_stays_in_scope(self):
        excludes = real_excludes()
        for path in (
            "VexSign/Features/Dashboard/Home/Views/AppStoreView.swift",
            # NativeSigning is first-party even though it lives under Packages/.
            "Packages/NativeSigning/Sources/Anything.swift",
            "VexSignTests/UnitTests/Persistence/CleanupOperationGuardTests.swift",
        ):
            self.assertFalse(drift.is_excluded(path, excludes), path)

    def test_glob_excludes_match_by_name_and_contents(self):
        excludes = drift.load_excludes("exclude *.xcodeproj,.build\n")
        self.assertTrue(drift.is_excluded("VexSign.xcodeproj/project.swift", excludes))
        self.assertTrue(drift.is_excluded(".build/checkouts/Foo.swift", excludes))
        self.assertFalse(drift.is_excluded("VexSign/App/Foo.swift", excludes))


class BaseResolutionTests(unittest.TestCase):
    def test_placeholder_and_malformed_shas_are_rejected(self):
        for value in ("0" * 40, "abc123", "Z" * 40, "A" * 40, BASE + "0", None, 42):
            self.assertFalse(drift.is_immutable_base(value), repr(value))

    def test_full_lowercase_hex_sha_is_accepted(self):
        self.assertTrue(drift.is_immutable_base(BASE))

    def test_pull_request_event_yields_the_pr_base(self):
        with tempfile.TemporaryDirectory() as temporary:
            event = Path(temporary) / "event.json"
            event.write_text(json.dumps({"pull_request": {"base": {"sha": BASE}}}))
            environment = {"GITHUB_EVENT_NAME": "pull_request", "GITHUB_EVENT_PATH": str(event)}
            with mock.patch.dict(os.environ, environment, clear=True):
                self.assertEqual(drift.resolve_base(), BASE)

    def test_push_event_yields_the_replaced_commit(self):
        with tempfile.TemporaryDirectory() as temporary:
            event = Path(temporary) / "event.json"
            event.write_text(json.dumps({"before": BASE}))
            environment = {"GITHUB_EVENT_NAME": "push", "GITHUB_EVENT_PATH": str(event)}
            with mock.patch.dict(os.environ, environment, clear=True):
                self.assertEqual(drift.resolve_base(), BASE)

    def test_first_push_and_missing_events_gate_nothing(self):
        cases = [
            {},  # no CI event at all: a local or manual run
            {"GITHUB_EVENT_NAME": "workflow_dispatch"},
            {"GITHUB_EVENT_NAME": "pull_request", "GITHUB_EVENT_PATH": "/nonexistent/event.json"},
        ]
        for environment in cases:
            with mock.patch.dict(os.environ, environment, clear=True):
                self.assertIsNone(drift.resolve_base(), environment)
        # git's placeholder for "no previous commit" must not be mistaken for a base.
        with tempfile.TemporaryDirectory() as temporary:
            event = Path(temporary) / "event.json"
            event.write_text(json.dumps({"before": "0" * 40}))
            environment = {"GITHUB_EVENT_NAME": "push", "GITHUB_EVENT_PATH": str(event)}
            with mock.patch.dict(os.environ, environment, clear=True):
                self.assertIsNone(drift.resolve_base())


class GateBehaviourTests(unittest.TestCase):
    def test_local_run_without_a_base_gates_nothing(self):
        # Exiting clean here is deliberate: a developer's machine has no CI event,
        # and failing it for missing history would teach people to ignore the gate.
        with mock.patch.dict(os.environ, {}, clear=True):
            self.assertEqual(drift.main([]), drift.EXIT_CLEAN)

    def test_a_change_touching_only_vendored_swift_gates_nothing(self):
        with mock.patch.object(drift, "resolve_base", return_value=BASE), mock.patch.object(
            drift,
            "changed_swift_files",
            return_value=({"Packages/SideSign/Sources/New.swift"}, set()),
        ), mock.patch.object(drift, "config_changed", return_value=False):
            with mock.patch.dict(os.environ, {}, clear=True):
                self.assertEqual(drift.main([]), drift.EXIT_CLEAN)

    def test_missing_formatter_fails_loudly_instead_of_passing(self):
        with mock.patch.object(drift, "resolve_base", return_value=BASE), mock.patch.object(
            drift, "changed_swift_files", return_value=({"VexSign/App/New.swift"}, set())
        ), mock.patch.object(drift.shutil, "which", return_value=None):
            self.assertEqual(drift.main([]), drift.EXIT_UNUSABLE)


class ConfigProbeTests(unittest.TestCase):
    """A diff that edits .swiftformat must prove the formatter still accepts it.

    This is the regression that mattered: an unknown option or rule makes swiftformat
    refuse to format anything at all, and this repository's config carried twenty-three
    such names for long enough that `make format` never worked and the report-only CI
    lint only ever printed the error. A config-only diff has no Swift in it for the lint
    to trip over, so the gate probes the file on its own instead.
    """

    def fake_formatter(self, produces_report, detail=""):
        def run(cmd, **kwargs):
            if produces_report and "--report" in cmd:
                Path(cmd[cmd.index("--report") + 1]).write_text("[]", encoding="utf-8")
            return subprocess.CompletedProcess(cmd, 0 if produces_report else 1, stdout="", stderr=detail)

        return run

    def probe(self, produces_report, detail=""):
        with mock.patch.object(drift, "resolve_base", return_value=BASE), mock.patch.object(
            drift, "changed_swift_files", return_value=(set(), set())
        ), mock.patch.object(drift, "config_changed", return_value=True), mock.patch.object(
            drift.shutil, "which", return_value="/usr/local/bin/swiftformat"
        ), mock.patch.object(
            drift.subprocess, "run", side_effect=self.fake_formatter(produces_report, detail)
        ):
            return drift.main([])

    def test_a_config_that_loads_passes(self):
        self.assertEqual(self.probe(True), drift.EXIT_CLEAN)

    def test_a_config_the_formatter_rejects_fails_loudly(self):
        self.assertEqual(self.probe(False, "error: Unknown rule 'unusedImport'"), drift.EXIT_UNUSABLE)

    def test_config_changed_reads_the_diff_listing(self):
        with mock.patch.object(drift, "git_output", return_value=".swiftformat\0README.md\0"):
            self.assertTrue(drift.config_changed(BASE))
        with mock.patch.object(drift, "git_output", return_value="README.md\0Makefile\0"):
            self.assertFalse(drift.config_changed(BASE))

    def test_probe_lints_a_throwaway_file_outside_the_repository(self):
        seen = {}

        def run(cmd, **kwargs):
            seen["cmd"] = cmd
            if "--report" in cmd:
                Path(cmd[cmd.index("--report") + 1]).write_text("[]", encoding="utf-8")
            return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")

        with mock.patch.object(drift, "resolve_base", return_value=BASE), mock.patch.object(
            drift, "changed_swift_files", return_value=(set(), set())
        ), mock.patch.object(drift, "config_changed", return_value=True), mock.patch.object(
            drift.shutil, "which", return_value="/usr/local/bin/swiftformat"
        ), mock.patch.object(drift.subprocess, "run", side_effect=run):
            drift.main([])

        # The probe lives in a temp directory, so the config has to be named explicitly:
        # swiftformat discovers .swiftformat by walking up from each input path.
        targets = [argument for argument in seen["cmd"] if argument.endswith(".swift")]
        self.assertEqual(len(targets), 1)
        self.assertFalse(targets[0].startswith(str(ROOT)), "the probe must not write into the repository")
        self.assertIn("--config", seen["cmd"])
        self.assertIn(str(ROOT / ".swiftformat"), seen["cmd"])


class WorkflowWiringTests(unittest.TestCase):
    def setUp(self):
        self.ci = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")

    def test_the_drift_gate_is_a_real_gate(self):
        # The whole-tree lint has to stay report-only until the backlog is cleared,
        # but the changed-lines gate has no backlog to inherit, so `continue-on-error`
        # on it would silently disable the only enforcing half.
        block = step_block(self.ci, "Swift style drift (changed lines)")
        self.assertIsNotNone(block, "the drift gate step is missing from ci.yml")
        self.assertNotIn("continue-on-error", block)
        self.assertIn("check-swift-format-drift.py", block)

    def test_the_whole_tree_run_stays_report_only(self):
        block = step_block(self.ci, "swiftformat lint (report)")
        self.assertIsNotNone(block)
        self.assertIn("continue-on-error: true", block, "promoting this needs the backlog cleared first")

    def test_the_gate_runs_after_the_formatter_is_installed(self):
        installed = self.ci.index("- name: Install swiftformat")
        gated = self.ci.index("- name: Swift style drift (changed lines)")
        self.assertLess(installed, gated, "the gate needs swiftformat on PATH")

    def test_the_self_test_runs_with_the_other_style_checks(self):
        for runner in (ROOT / "Makefile", ROOT / ".github/workflows/ci.yml"):
            # assertTrue rather than assertIn: the haystack is a whole build file,
            # and dumping it as a failure message buries the one useful fact.
            self.assertTrue(
                "test_swift_format_drift.py" in runner.read_text(encoding="utf-8"),
                f"{runner.name} must run the gate's own regressions",
            )


if __name__ == "__main__":
    unittest.main(verbosity=2)
