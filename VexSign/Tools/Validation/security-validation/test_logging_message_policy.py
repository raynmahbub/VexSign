#!/usr/bin/env python3
"""Regression guard: OSLog messages must be one interpolated literal.

`Logger.error(_:)` and friends take an `OSLogMessage`, not a `String`. That type is
built by string interpolation, so `+` concatenation does not work on it — the
compiler rejects `"a" + value` with:

    cannot convert value of type 'String' to expected argument type 'OSLogMessage'

This is easy to write and impossible to see: the call looks like ordinary logging,
and every portable check here (localisation, docs links, `swift-syntax` when it is
skipped) passes, because none of them typechecks Swift. It was in fact introduced
into three files by the audit's own storage change and caught only by the macOS
`build` and `tests` jobs.

Two properties are pinned:

  1. A `Logger.<level>(` call must not concatenate with `+`.
  2. A redacted description passed to OSLog must be marked `privacy: .public`.
     OSLog interpolation defaults to `.private`, which renders as `<private>` in
     Console — so the diagnostic this audit added specifically to stop failures
     being silent would itself be unreadable. `FileLogger` sets the same thing on
     the one path that writes user-visible text.
  3. A log call names a URL by its host (`url.logSafeDescription`), never by
     `url.absoluteString`. Query strings carry premium-feed and signed-download
     tokens, and a path can name a private repository. `privacy: .public` makes the
     text readable, which is the point — it must therefore not be the whole URL.
     The file logger is held to the same rule: its output is exported by the user.

Scope is `Logger.<level>(` calls only. String concatenation elsewhere is normal.

Not covered: a *property* interpolated into OSLog from inside a nested closure
needs an explicit `self.` (`reference to property '_uuid' in closure requires
explicit use of 'self'`). Deciding that from source needs scope analysis — a
closure, or not; a property, or a parameter shadowing one — and a heuristic based
on indentation produced false positives on parameters and on SwiftUI view
properties read from ordinary methods. Rather than ship a check that cries wolf,
it is left out; that error is caught by the macOS jobs, which is how the one real
instance (`self._uuid`) was found.
"""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
SWIFT_ROOTS = [ROOT / "VexSign/App/iOS", ROOT / "VexSign/Packages/NativeSigning", ROOT / "VexSign/Packages/NimbleKit", ROOT / "VexSign/Packages/SideSign"]

# `Logger.misc.fault(`, `Logger.signing.error(`, `logger.info(` ...
LOG_CALL = re.compile(r"\bLogger\.\w+\.(?:trace|debug|info|notice|warning|error|fault|critical)\s*\(")
# The OSLog levels, used to find the end of the argument list.
LEVELS = ("trace", "debug", "info", "notice", "warning", "error", "fault", "critical")
# The file logger writes into a file the user can export from diagnostics, so the same
# rule applies to it.
FILE_LOG_CALL = re.compile(r"\bFileLogger\.(?:log|error|warn)\s*\(")

SKIP_DIRS = {"Vendor", ".build", "build", "DerivedData", "Pods", "node_modules", ".git"}


def swift_files() -> list[Path]:
    out: list[Path] = []
    for root in SWIFT_ROOTS:
        if not root.is_dir():
            continue
        for path in root.rglob("*.swift"):
            if any(part in SKIP_DIRS for part in path.parts):
                continue
            out.append(path)
    return sorted(out)


def log_call_arguments(text: str, start: int) -> str:
    """Return the text of the call's argument list, starting at the '(' index."""
    depth = 0
    i = start
    in_string = False
    escape = False
    while i < len(text):
        ch = text[i]
        if in_string:
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == '"':
                in_string = False
        else:
            if ch == '"':
                in_string = True
            elif ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
                if depth == 0:
                    return text[start : i + 1]
        i += 1
    return text[start:]


def strip_comments(text: str) -> str:
    """Remove // and /* */ comments, leaving string literals intact."""
    out: list[str] = []
    i = 0
    in_string = False
    escape = False
    while i < len(text):
        ch = text[i]
        if in_string:
            out.append(ch)
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == '"':
                in_string = False
            i += 1
            continue
        if ch == '"':
            in_string = True
            out.append(ch)
            i += 1
            continue
        if text.startswith("//", i):
            end = text.find("\n", i)
            i = len(text) if end == -1 else end
            continue
        if text.startswith("/*", i):
            end = text.find("*/", i + 2)
            i = len(text) if end == -1 else end + 2
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def concatenated_log_calls(text: str) -> list[str]:
    """Redacted-free scan: OSLog calls that use `+` to join their message."""
    findings: list[str] = []
    for match in LOG_CALL.finditer(text):
        args = log_call_arguments(text, match.end() - 1)
        # A `+` at the top level of the argument list is the concatenation bug.
        # Ignore `+` inside parentheses of a nested call (`String(format:)`, etc.).
        depth = 0
        in_string = False
        escape = False
        for ch in args[1:]:
            if in_string:
                if escape:
                    escape = False
                elif ch == "\\":
                    escape = True
                elif ch == '"':
                    in_string = False
                continue
            if ch == '"':
                in_string = True
            elif ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
            elif ch == "+" and depth == 0:
                findings.append(f"{match.group(0)} … uses `+`")
                break
    return findings


def private_redactions(text: str) -> list[str]:
    """`LogRedaction.redact(...)` interpolated into OSLog without `privacy: .public`."""
    findings: list[str] = []
    for match in re.finditer(r"\\\(\s*LogRedaction\.redact\((?:[^()]|\([^()]*\))*\)", text):
        # `privacy:` sits after the closing paren, so look at the whole interpolation:
        # everything from `\(` to the closing quote of the literal.
        tail = text[match.start() :]
        close = tail.find('"')
        span = tail if close == -1 else tail[:close]
        if "privacy:" not in span:
            findings.append(span)
    return findings


def full_url_logs(text: str) -> list[str]:
    """Log calls that interpolate a whole URL instead of its host."""
    findings: list[str] = []
    for pattern in (LOG_CALL, FILE_LOG_CALL):
        for match in pattern.finditer(text):
            args = log_call_arguments(text, match.end() - 1)
            if "absoluteString" in args:
                findings.append(f"{match.group(0)} … interpolates `absoluteString`")
    return findings


class LoggingMessagePolicyTests(unittest.TestCase):
    def test_container_path_redaction_preserves_error_codes_and_public_urls(self):
        source = (ROOT / 'VexSign/App/iOS/Infrastructure/Diagnostics/LogRedaction.swift').read_text()
        rule = re.search(r'// Local container paths.*?pattern: #"(.*?)"#,', source, re.DOTALL)
        self.assertIsNotNone(rule, 'The production container-path rule must exist')
        pattern = re.compile(rule.group(1))
        for path in [
            '/private/var/mobile/Containers/Data/VexSign.sqlite',
            '/var/mobile/Containers/Data/VexSign.sqlite-wal',
            'file:///private/var/containers/Bundle/Application/fixture/VexSign.app',
            'file:///Users/fixture/Library/Developer/CoreSimulator/Devices/fixture-device/data/Containers/Data/fixture/VexSign.sqlite',
        ]:
            output = pattern.sub('<redacted>', 'Failed to open "' + path + '" (SQLite error 11)')
            self.assertEqual(output, 'Failed to open "<redacted>" (SQLite error 11)')
            self.assertEqual(pattern.sub('<redacted>', output), output)
        for text in ['GET https://example.com/var/mobile/backup.sqlite',
                     'GET https://example.com/Users/fixture/Library/Developer/CoreSimulator/Devices/help',
                     'SQLite error 11', 'Signed Example.app (com.example.app)']:
            self.assertEqual(pattern.sub('<redacted>', text), text)

    def test_no_oslog_call_concatenates_its_message(self):
        offenders = []
        for path in swift_files():
            text = strip_comments(path.read_text(encoding="utf-8", errors="replace"))
            for finding in concatenated_log_calls(text):
                offenders.append(f"{path.relative_to(ROOT)}: {finding}")
        self.assertEqual(
            offenders,
            [],
            "an OSLog call joins its message with `+`; OSLogMessage is built by "
            "interpolation, so this does not compile:\n  " + "\n  ".join(offenders),
        )

    def test_logs_name_the_host_instead_of_the_whole_url(self):
        # Query strings carry premium and signed-download tokens, and paths can name a
        # private repository. `URL.logSafeDescription` keeps the scheme/host/port that a
        # diagnostic actually needs.
        offenders = []
        for path in swift_files():
            text = strip_comments(path.read_text(encoding="utf-8", errors="replace"))
            for finding in full_url_logs(text):
                offenders.append(f"{path.relative_to(ROOT)}: {finding}")
        self.assertEqual(
            offenders,
            [],
            "log `url.logSafeDescription` instead of `url.absoluteString`:\n  " + "\n  ".join(offenders),
        )

    def test_redacted_descriptions_are_public_in_oslog(self):
        # OSLog interpolation defaults to `.private`, which hides the text the audit
        # added specifically so a failure would stop being silent.
        offenders = []
        for path in swift_files():
            text = strip_comments(path.read_text(encoding="utf-8", errors="replace"))
            for finding in private_redactions(text):
                offenders.append(f"{path.relative_to(ROOT)}: {finding}")
        self.assertEqual(
            offenders,
            [],
            "a redacted description reaches OSLog without `privacy: .public`, so it "
            "renders as <private>:\n  " + "\n  ".join(offenders),
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
