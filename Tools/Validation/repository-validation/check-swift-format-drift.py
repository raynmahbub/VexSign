#!/usr/bin/env python3
"""Gate the Swift style drift a change introduces, not the backlog it inherits.

`swiftformat --lint .` across the whole tree still lists hundreds of pre-existing
files -- test_style_config.py counts 268 tab-indented first-party Swift files and
167 more that mix both styles -- so ci.yml keeps that run report-only. Promoting
it to a gate today would fail every pull request over code the pull request never
touched, and clearing the backlog is a one-time mechanical pass that needs the
formatter installed. What must not regress is the part a diff owns, which is what
this gate enforces: the condition the report-only step exists to reach, "so new
files cannot reintroduce the drift".

Scope mirrors ci-scope.py -- the complete PR/push diff against an immutable base,
never just the latest commit. Ownership is per line, from `git diff -U0`, so a
pure deletion owns no line and a rewritten line owns exactly one. An added file is
owned outright because every line in it is new.

The formatter's JSON reporter is parsed rather than its console text: the schema
(`file`, `line`, `reason`, `rule_id`) is stable and machine-readable, while the
console wording is not. `--report` keeps that JSON out of the same stream as the
formatter's warnings, and lint's non-zero exit means "violations exist" rather
than "the tool failed", so only a missing or unparsable report is treated as the
gate being unable to run. A gate that cannot read its input fails loudly; silently
reporting no violations would pass every pull request.
"""
from __future__ import annotations

from pathlib import Path
from typing import NamedTuple
import argparse
import fnmatch
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[3]
SWIFTFORMAT_CONFIG = ROOT / ".swiftformat"

# `git diff -U0` hunk header. Only the new side matters: it gives the first owned
# line and how many follow. Either count may be omitted, which git means as one
# (`@@ -200 +223 @@`), and a new-side count of zero is a pure deletion that owns
# no line at all (`@@ -202,7 +224,0 @@`). The trailing hunk context is a function
# or type name and is deliberately not captured.
HUNK = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@", re.MULTILINE)

EXIT_CLEAN = 0
EXIT_DRIFT = 1
EXIT_UNUSABLE = 2

MAX_REPORTED = 40


class Violation(NamedTuple):
    """One formatter complaint, attributed to a repository-relative file and line."""

    path: str
    line: int
    rule: str
    reason: str


def load_excludes(config_text):
    """Returns the `exclude` list from .swiftformat, as path fragments.

    Read from the formatter's own config instead of restated here: the vendored
    upstream trees are excluded there on purpose, because their style is
    upstream's to own and reformatting them turns the next re-vendor into a wall
    of noise. test_style_config.py pins that config; this keeps the gate reading
    the same single source rather than a second copy that could drift from it.
    """
    for raw in config_text.splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        key, _, value = line.partition(" ")
        if key.strip() == "exclude":
            return [part.strip() for part in value.split(",") if part.strip()]
    return []


def is_excluded(path, excludes):
    """True when a repository-relative path falls under one of the excludes."""
    for fragment in excludes:
        fragment = fragment.strip("/")
        if not fragment:
            continue
        if path == fragment or path.startswith(fragment + "/"):
            return True
        if fnmatch.fnmatch(path, fragment) or fnmatch.fnmatch(path, fragment + "/*"):
            return True
        if fnmatch.fnmatch(Path(path).name, fragment):
            return True
    return False


def changed_line_ranges(diff_text):
    """Returns the new-file line numbers a `git diff -U0` patch adds or rewrites."""
    owned = set()
    for match in HUNK.finditer(diff_text):
        start = int(match.group(1))
        count = 1 if match.group(2) is None else int(match.group(2))
        owned.update(range(start, start + count))
    return owned


def relative_path(path):
    """Returns a repository-relative posix path; the formatter may echo absolute ones."""
    if not path:
        return ""
    text = str(path).replace("\\", "/")
    prefix = str(ROOT).replace("\\", "/").rstrip("/") + "/"
    if text.startswith(prefix):
        text = text[len(prefix):]
    while text.startswith("./"):
        text = text[2:]
    return text


def parse_report(report_text):
    """Returns the violations in a `swiftformat --lint --reporter json` report.

    The schema is the formatter's own -- JSONReporter encoding Formatter.Change
    with snake_case keys -- so `ruleID` arrives as `rule_id`. An entry that cannot
    be attributed to a path is dropped rather than guessed at, because a violation
    with no file cannot be scoped to a diff. Anything else that does not fit the
    schema raises: refusing to read the report is safer than reading it as empty.
    """
    text = report_text.strip()
    if not text:
        return []
    try:
        items = json.loads(text)
    except ValueError as error:
        raise ValueError(f"swiftformat JSON report did not parse: {error}") from error
    if not isinstance(items, list):
        raise ValueError("swiftformat JSON report is not a list of violations")
    violations = []
    for item in items:
        if not isinstance(item, dict):
            raise ValueError("swiftformat JSON report contains a non-object entry")
        line = item.get("line")
        if not isinstance(line, int) or isinstance(line, bool):
            raise ValueError(f"swiftformat JSON report entry has no integer line: {item!r}")
        path = relative_path(item.get("file"))
        if not path:
            continue
        violations.append(
            Violation(path, line, str(item.get("rule_id") or "unknown"), str(item.get("reason") or ""))
        )
    return violations


def attribute(violations, added, owned_lines):
    """Returns the violations landing on lines this change owns.

    An added file is owned outright -- every line in it is new, which is the case
    the report-only whole-tree lint exists to protect. A modified file is owned
    only where the diff says a line was added or rewritten, so the backlog already
    in that file stays out of the gate and a change is never failed for code it did
    not touch.
    """
    owned = []
    for violation in violations:
        if violation.path in added:
            owned.append(violation)
        elif violation.line in owned_lines.get(violation.path, ()):
            owned.append(violation)
    return owned


def is_immutable_base(value):
    """True for a full lowercase hex sha that is not git's all-zero first-push placeholder."""
    return (
        isinstance(value, str)
        and len(value) == 40
        and all(character in "0123456789abcdef" for character in value)
        and value != "0" * 40
    )


def resolve_base():
    """Returns the diff base for this CI event, or None when there is nothing to compare.

    Same source and same validation as ci-scope.py: a pull request diffs against
    its base sha and a push against the commit it replaced. Anything unverifiable
    -- a first push, a manual dispatch, a local run -- yields None so the caller
    can say the gate did not run instead of implying the tree is clean.
    """
    if os.environ.get("GITHUB_EVENT_NAME") not in ("pull_request", "push"):
        return None
    try:
        event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
        base = event["pull_request"]["base"]["sha"] if "pull_request" in event else event["before"]
    except (KeyError, OSError, TypeError, UnicodeError, ValueError):
        return None
    return base if is_immutable_base(base) else None


def git_output(*arguments):
    """Returns stdout of a git command run at the repository root."""
    completed = subprocess.run(("git",) + arguments, cwd=ROOT, capture_output=True, check=True)
    return completed.stdout.decode("utf-8", "replace")


def changed_swift_files(base):
    """Returns (added, modified) repository-relative Swift paths between base and HEAD."""
    added, modified = set(), set()
    for bucket, selector in ((added, "AC"), (modified, "M")):
        listing = git_output(
            "diff", "--name-only", "--no-renames", f"--diff-filter={selector}", "-z", base, "HEAD"
        )
        for raw in listing.split("\0"):
            if raw.endswith(".swift"):
                bucket.add(raw)
    return added, modified


def config_changed(base):
    """True when this change edits .swiftformat itself."""
    listing = git_output("diff", "--name-only", "--no-renames", "-z", base, "HEAD")
    return any(raw == SWIFTFORMAT_CONFIG.name for raw in listing.split("\0"))


# Deliberately trivial and kept outside the repository: the probe is asking one
# question -- does the pinned formatter accept every option and rule name in
# .swiftformat -- so any violations it reports about the probe are irrelevant.
PROBE_SOURCE = "import Foundation\n\nfunc probe() -> Int {\n    1\n}\n"


def probe_config():
    """Returns EXIT_CLEAN when .swiftformat loads, EXIT_UNUSABLE when it does not.

    swiftformat rejects an unknown option or rule outright and then formats nothing,
    which is how this repository's config spent its life broken: `make format` failed
    for everyone and the report-only CI lint printed only that error. A diff that edits
    the config but no Swift file gives the lint below nothing to chew on, so the config
    gets proved loadable on its own instead.
    """
    with tempfile.TemporaryDirectory() as directory:
        probe = Path(directory) / "Probe.swift"
        probe.write_text(PROBE_SOURCE, encoding="utf-8")
        report = Path(directory) / "probe-report.json"
        completed = subprocess.run(
            [
                "swiftformat", "--lint", "--config", str(SWIFTFORMAT_CONFIG),
                "--reporter", "json", "--report", str(report), str(probe),
            ],
            cwd=ROOT,
            capture_output=True,
            text=True,
        )
        if not report.exists():
            detail = (completed.stderr or completed.stdout or "").strip()
            print(
                f"::error::.swiftformat could not be loaded by swiftformat (exit {completed.returncode}); "
                "an unknown option or rule name makes the formatter refuse to format anything.",
                file=sys.stderr,
            )
            if detail:
                print(detail[-2000:], file=sys.stderr)
            return EXIT_UNUSABLE
    print("Swift style drift: .swiftformat changed and the pinned formatter still loads it.")
    return EXIT_CLEAN


def main(argv=None):
    parser = argparse.ArgumentParser(description="Fail a change on Swift style drift it introduces.")
    parser.add_argument("--base", help="immutable diff base; defaults to the CI event's base")
    parser.add_argument(
        "--config", default=str(SWIFTFORMAT_CONFIG), help="swiftformat config read for excludes"
    )
    arguments = parser.parse_args(argv)

    base = arguments.base if is_immutable_base(arguments.base) else resolve_base()
    if base is None:
        print(
            "Swift style drift: no immutable base to diff against (local run, first push or "
            "manual dispatch), so there is nothing to scope a gate to."
        )
        return EXIT_CLEAN

    excludes = load_excludes(Path(arguments.config).read_text(encoding="utf-8"))
    added, modified = changed_swift_files(base)
    in_scope = {path for path in added | modified if not is_excluded(path, excludes)}
    added = {path for path in added if path in in_scope}
    modified = {path for path in modified if path in in_scope}
    if not in_scope:
        touched_config = config_changed(base)
        if not touched_config:
            print(f"Swift style drift: no first-party Swift file changed against {base[:10]}.")
            return EXIT_CLEAN

    if shutil.which("swiftformat") is None:
        print(
            "::error::swiftformat is not installed, so the style-drift gate cannot lint the "
            f"{len(in_scope)} changed Swift file(s).",
            file=sys.stderr,
        )
        return EXIT_UNUSABLE

    if not in_scope:
        # Only the config moved. Linting changed Swift below would have proved the config
        # loadable as a side effect, but there is no Swift in this diff to prove it with.
        return probe_config()

    owned_lines = {
        path: changed_line_ranges(git_output("diff", "-U0", "--no-renames", base, "HEAD", "--", path))
        for path in sorted(modified)
    }

    handle = tempfile.NamedTemporaryFile(suffix=".json", delete=False)
    handle.close()
    report = Path(handle.name)
    try:
        completed = subprocess.run(
            ["swiftformat", "--lint", "--reporter", "json", "--report", str(report), *sorted(in_scope)],
            cwd=ROOT,
            capture_output=True,
            text=True,
        )
        if not report.exists():
            # A non-zero exit with a report is lint doing its job; no report at all
            # means the formatter never ran, and the gate must not pass on that.
            detail = (completed.stderr or completed.stdout or "").strip()
            print(
                f"::error::swiftformat produced no report (exit {completed.returncode}).",
                file=sys.stderr,
            )
            if detail:
                print(detail[-2000:], file=sys.stderr)
            return EXIT_UNUSABLE
        try:
            violations = parse_report(report.read_text(encoding="utf-8"))
        except ValueError as error:
            print(f"::error::{error}", file=sys.stderr)
            return EXIT_UNUSABLE
    finally:
        report.unlink(missing_ok=True)

    drift = attribute(violations, added, owned_lines)
    if not drift:
        print(
            f"Swift style drift: {len(violations)} pre-existing violation(s) across "
            f"{len(in_scope)} changed Swift file(s), none on a line this change owns."
        )
        return EXIT_CLEAN

    print(
        f"Swift style drift: {len(drift)} violation(s) on lines this change owns, across "
        f"{len(in_scope)} changed Swift file(s)."
    )
    for violation in drift[:MAX_REPORTED]:
        print(f"  {violation.path}:{violation.line}: ({violation.rule}) {violation.reason}")
    if len(drift) > MAX_REPORTED:
        print(f"  ... and {len(drift) - MAX_REPORTED} more")
    print(
        "Format the lines this change owns (`make format FIX=1`, or run swiftformat on just "
        "these files). The whole-tree run stays report-only until the backlog is cleared."
    )
    return EXIT_DRIFT


if __name__ == "__main__":
    sys.exit(main())
