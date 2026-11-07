#!/usr/bin/env python3
"""Surface failing simulator tests as GitHub annotations after `xcodebuild test`.

Newer Xcode writes per-test results into the xcresult bundle, not into
xcodebuild's stdout, so a failed run otherwise shows one `** TEST FAILED **`
marker and nothing else. This reads the bundle plus the raw log and emits:

  * every failing test by name, with location and message,
  * the crash stack (callee <- caller) from exported diagnostics,
  * the log context around the failure marker and known host traps.

GitHub keeps at most ten annotations per step, so facts are packed into a
handful of lines (a crash stack is one annotation, not thirty) and the
complete list goes to the step log. Always exits 0: this runs after a
failure and must never replace the original error.

Environment: RESULT_BUNDLE, TEST_LOG, TEST_EXIT, SUMMARY_JSON.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys

ANNOTATION = "::error file=.github/workflows/ci.yml,line=1::"


def annotate(text: str) -> None:
    print(ANNOTATION + "".join(c for c in text if c not in "\r\n")[:900], flush=True)


def run_quiet(args: list[str]) -> None:
    try:
        with open(os.devnull, "wb") as devnull:
            subprocess.run(args, stdout=devnull, stderr=devnull, check=False)
    except OSError:
        pass


def dump(path: str, args: list[str]) -> None:
    try:
        with open(path, "wb") as out, open(os.devnull, "wb") as devnull:
            subprocess.run(args, stdout=out, stderr=devnull, check=False)
    except OSError:
        pass


def failed_tests(tests_path: str) -> list[tuple[str, list[str]]]:
    """Every failed node of `xcresulttool get test-results tests`, deduplicated."""
    try:
        with open(tests_path) as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return []
    seen: set[tuple] = set()
    found: list[tuple[str, list[str]]] = []

    def walk(node) -> None:
        if isinstance(node, dict):
            if node.get("result") == "failed":
                name = node.get("name") or node.get("nodeIdentifier") or "?"
                if not (name.startswith("All tests") or name == "VexSignTests"):
                    messages = [detail["failureMessage"]
                                for detail in node.get("failureMessages") or []
                                if isinstance(detail, dict) and detail.get("failureMessage")]
                    key = (name, tuple(messages))
                    if key not in seen:
                        seen.add(key)
                        found.append((name, messages))
            for value in node.values():
                walk(value)
        elif isinstance(node, list):
            for value in node:
                walk(value)

    walk(data)
    return found


def crash_stack(diag_dir: str) -> str:
    """Faulting-thread symbols from the first readable .ips/.crash export."""
    for base, _dirs, names in os.walk(diag_dir):
        for name in names:
            if not name.endswith((".ips", ".crash")):
                continue
            try:
                with open(os.path.join(base, name), encoding="utf-8", errors="replace") as handle:
                    payload = json.loads(handle.read().splitlines()[-1])
                threads = payload.get("threads") or []
                index = payload.get("faultingThread")
                if not isinstance(index, int) or index >= len(threads):
                    index = next((i for i, t in enumerate(threads) if t.get("triggered")), 0)
                frames = (threads[index].get("frames") or []) if threads else []
                symbols = [f.get("symbol") or f.get("imageOffset") or "?" for f in frames]
            except Exception:
                continue
            if symbols:
                return " <- ".join(str(s)[:70] for s in symbols[:24])
    return ""


def summary_lines(summary_path: str, tests_path: str) -> list[str]:
    """Counts, every named failure, raw detail for the first few, plus stragglers."""
    lines: list[str] = []
    summary: dict = {}
    try:
        with open(summary_path) as handle:
            summary = json.load(handle)
        bits = [f"result={summary.get('result', '?')}"]
        for key in ("totalTestCount", "passedTests", "failedTests", "skippedTests", "expectedFailures"):
            if summary.get(key) is not None:
                bits.append(f"{key}={summary[key]}")
        lines.append("SUMMARY " + " ".join(str(b) for b in bits))

        named = summary.get("testFailures") or []
        lines.append(f"failing tests: {len(named)}")
        for failure in named:
            title = str(failure.get("testName") or "?")[:200]
            location = (failure.get("sourceCodeContext") or {}).get("location") or {}
            where = ""
            if location.get("filePath"):
                where = " @ %s:%s" % (location.get("filePath"), location.get("lineNumber", "?"))
            detail = str(failure.get("failureText") or "").replace("\n", " ")[:300]
            lines.append("FAILED " + title + where + (" — " + detail if detail else ""))
        for failure in named[:2]:
            # The assertion with its line lives here; print a couple so one run
            # explains itself without a second run.
            lines.append("RAW " + json.dumps(failure)[:700])
        for failure in named[:5]:
            title = str(failure.get("testName") or "?")[:200]
            detail = str(failure.get("failureText") or "").replace("\n", " ")[:300]
            lines.append("TEST " + title + (" — " + detail if detail else ""))
    except Exception as error:
        lines.append("SUMMARY unavailable: " + str(error)[:160])

    # Anything `test-results tests` knows but the summary did not name: a
    # crash can report zero failing tests.
    seen = {str(item.get("testName") or "") for item in (summary.get("testFailures") or [])}
    for name, messages in failed_tests(tests_path):
        if name not in seen:
            lines.append("FAILED " + name[:200] + (" — " + messages[0][:300] if messages else ""))
    return lines


def log_context(path: str) -> list[str]:
    """A trap in the host app prints just above `** TEST FAILED **`; that
    context is worth more than the tail of a log that is mostly chatter."""
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            lines = handle.read().splitlines()
    except OSError:
        return []
    picked: list[str] = []
    marker = next((i for i, line in enumerate(lines) if "** TEST FAILED **" in line), None)
    if marker is not None:
        before = [line.strip() for line in lines[max(0, marker - 40):marker] if line.strip()][-3:]
        after = [line.strip() for line in lines[marker + 1:marker + 30] if line.strip()][:4]
        picked = before + after
    offender = re.compile(r"ran off the main queue|CoreData: error|NSInternalInconsistencyException")
    flagged = [line.strip() for line in lines if offender.search(line)][-4:]
    picked = flagged + picked
    if not picked:
        pick = re.compile(r"error:|BUILD FAILED|Fatal error|Precondition failed|SIGABRT")
        picked = [line.strip() for line in lines if pick.search(line)][-6:]
    return [line[:400] for line in picked[-8:]]


def emit(line: str) -> None:
    if line.startswith("STACK "):
        annotate("crash stack (callee <- caller): " + line[6:])
    elif line.startswith("TEST "):
        annotate(line[5:])
    elif line.startswith("SUMMARY "):
        annotate(line[8:])
    else:
        # FAILED/RAW stay out of the annotations: GitHub caps those at ten per
        # step, and the log is where the complete list has to live.
        print(line, flush=True)


def main() -> int:
    bundle = os.environ.get("RESULT_BUNDLE", "")
    log = os.environ.get("TEST_LOG", "")
    summary_path = os.environ.get("SUMMARY_JSON", "")
    temp = os.path.dirname(summary_path) or os.environ.get("RUNNER_TEMP", ".")

    if os.path.isfile(log):
        with open(log, "rb") as handle:
            lines = str(sum(chunk.count(b"\n") for chunk in iter(lambda: handle.read(1 << 20), b"")))
    else:
        lines = "absent"
    annotate(f"xcodebuild test exit={os.environ.get('TEST_EXIT') or 'unknown'}; "
             f"xcresult={'present' if os.path.isdir(bundle) else 'absent'}; log={lines} lines")

    if os.path.isdir(bundle):
        print("::group::failing tests", flush=True)
        tests_path = os.path.join(temp, "tests.json")
        summary_path = summary_path or os.path.join(temp, "summary.json")
        dump(summary_path, ["xcrun", "xcresulttool", "get", "test-results", "summary",
                            "--path", bundle, "--format", "json"])
        dump(tests_path, ["xcrun", "xcresulttool", "get", "test-results", "tests",
                          "--path", bundle, "--format", "json"])
        diag_dir = os.path.join(temp, "xcresult-diagnostics")
        run_quiet(["xcrun", "xcresulttool", "export", "diagnostics",
                   "--path", bundle, "--output-path", diag_dir])

        stack = crash_stack(diag_dir)
        if stack:
            emit("STACK " + stack)
        for line in summary_lines(summary_path, tests_path):
            emit(line)
        print("::endgroup::", flush=True)

    if os.path.isfile(log):
        for line in log_context(log):
            annotate("log: " + line)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:  # diagnostics never mask the original failure
        print(f"::warning::surface_test_failures: {str(error)[:200]}", flush=True)
        sys.exit(0)
