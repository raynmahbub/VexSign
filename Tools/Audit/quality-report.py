#!/usr/bin/env python3
"""Turn native test artifacts into an honest pass/fail/skipped/blocked report.

The report is built from `xcresulttool get test-results tests`, not from xcodebuild's
exit code alone. It refuses to call a run green when no test executed, when a leaf test
failed, when the raw log contains a crash marker, or — with --require-device — when the
per-feature device report is not accepted. It never converts a skipped test into a pass.
"""

import argparse
import importlib.util
import json
import re
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RESULT_VALUES = {"passed", "failed", "skipped"}
CRASH_SIGNAL = re.compile(r"EXC_BAD_ACCESS|SIGABRT|SIGSEGV|Thread \d+ Crashed|\*\*\* TEST FAILED \*\*\*")


def _feature_module():
    path = ROOT / "Tools/Audit/feature-acceptance.py"
    spec = importlib.util.spec_from_file_location("vexsign_feature_acceptance", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def collect_tests(node):
    """Return leaf test results; container nodes only carry their children."""

    def walk(value):
        if isinstance(value, list):
            tests = []
            for item in value:
                tests.extend(walk(item))
            return tests
        if not isinstance(value, dict):
            return []
        children = []
        for child in value.values():
            if isinstance(child, (dict, list)):
                children.extend(walk(child))
        result = str(value.get("result", "")).lower()
        if result in RESULT_VALUES and not children:
            name = value.get("name") or value.get("nodeIdentifier") or "unnamed test"
            messages = []
            for detail in value.get("failureMessages") or []:
                if isinstance(detail, dict):
                    text = detail.get("failureMessage")
                else:
                    text = str(detail)
                if text:
                    messages.append(str(text))
            return [{"name": str(name), "result": result, "messages": messages}]
        return children

    return walk(node)


def crash_signals(log_path):
    if not log_path or not Path(log_path).is_file():
        return []
    text = Path(log_path).read_text(encoding="utf-8", errors="replace")
    return sorted(set(match.group(0) for match in CRASH_SIGNAL.finditer(text)))


def device_summary(report_path, require, ipa, commit):
    if not report_path:
        return {"status": "blocked", "reason": "No device report supplied", "errors": [] if not require else ["Device evidence is required"]}
    try:
        report = json.loads(Path(report_path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        return {"status": "blocked", "reason": str(error), "errors": [str(error)] if require else []}
    cases = report.get("cases") if isinstance(report, dict) else None
    if not isinstance(cases, dict):
        return {"status": "blocked", "reason": "cases must be an object", "errors": ["Device report has no cases"]}
    counts = {}
    for case in cases.values():
        key = case.get("result", "invalid") if isinstance(case, dict) else "invalid"
        counts[key] = counts.get(key, 0) + 1
    errors = []
    if require:
        errors = _feature_module().check_report(report, ipa, commit)
    return {
        "status": "accepted" if require and not errors else ("rejected" if require else "reported"),
        "counts": counts,
        "errors": errors,
    }


def build_report(test_results=None, test_log=None, device_report_path=None,
                 require_device=False, ipa=None, commit=None):
    problems = []
    tests = []
    if not test_results or not Path(test_results).is_file():
        problems.append("No xcresult test-results JSON was produced; no test is reported as passed")
    else:
        try:
            payload = json.loads(Path(test_results).read_text(encoding="utf-8"))
        except json.JSONDecodeError as error:
            problems.append(f"Unreadable test results: {error}")
            payload = None
        if payload is not None:
            tests = collect_tests(payload)

    counts = {key: sum(1 for test in tests if test["result"] == key) for key in sorted(RESULT_VALUES)}
    executed = counts.get("passed", 0) + counts.get("failed", 0)
    if executed == 0:
        problems.append("No test executed; a suite of skipped tests is not a pass")
    failures = [test for test in tests if test["result"] == "failed"]
    problems.extend(f"FAILED {test['name']}: {'; '.join(test['messages']) or 'no failure message'}" for test in failures)

    signals = crash_signals(test_log)
    problems.extend(f"CRASH {signal}" for signal in signals)

    device = device_summary(device_report_path, require_device, ipa, commit)
    problems.extend(device["errors"])

    report = {
        "schema": 1,
        "generated_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "status": "failed" if problems else "passed",
        "tests": {"counts": counts, "executed": executed,
                  "failed": [test["name"] for test in failures],
                  "skipped": [test["name"] for test in tests if test["result"] == "skipped"]},
        "crash_signals": signals,
        "device": device,
        "blocked": problems,
    }
    return report


def markdown(report):
    lines = [
        "# Automated quality report",
        "",
        f"**Status:** {report['status'].upper()}",
        "",
        "## Test execution",
        "",
        f"- Passed: {report['tests']['counts'].get('passed', 0)}",
        f"- Failed: {report['tests']['counts'].get('failed', 0)}",
        f"- Skipped: {report['tests']['counts'].get('skipped', 0)}",
        f"- Executed: {report['tests']['executed']}",
        "",
    ]
    for title, key in (("Failed tests", "failed"), ("Skipped tests", "skipped")):
        lines.extend([f"## {title}", ""])
        names = report["tests"][key]
        lines.extend([f"- {name}" for name in names] or ["- None"])
        lines.append("")
    lines.extend(["## Crash signals", ""])
    lines.extend([f"- {signal}" for signal in report["crash_signals"]] or ["- None detected"])
    lines.extend(["", "## Device evidence", "",
                  f"- Status: {report['device']['status']}",
                  f"- Cases: {json.dumps(report['device'].get('counts', {}), sort_keys=True)}",
                  f"- Reason: {report['device'].get('reason', 'n/a')}", ""])
    lines.extend(["## Blocked / failed checks", ""])
    lines.extend([f"- {problem}" for problem in report["blocked"]] or ["- None"])
    lines.append("")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--test-results", help="JSON from `xcrun xcresulttool get test-results tests`")
    parser.add_argument("--test-log", help="Raw xcodebuild test log, scanned for crash markers")
    parser.add_argument("--device-report", help="feature-acceptance.py report")
    parser.add_argument("--require-device", action="store_true", help="Fail unless the device report is accepted")
    parser.add_argument("--ipa", help="IPA bound to the device report")
    parser.add_argument("--commit", help="Commit bound to the device report")
    parser.add_argument("--json", required=True, help="Where to write the JSON report")
    parser.add_argument("--markdown", help="Where to write the Markdown summary")
    parser.add_argument("--github-output", help="Append status/count keys to this GitHub output file")
    args = parser.parse_args()

    if args.require_device and not (args.ipa and args.commit):
        parser.exit(2, "error: --require-device needs --ipa and --commit\n")

    report = build_report(
        test_results=args.test_results,
        test_log=args.test_log,
        device_report_path=args.device_report,
        require_device=args.require_device,
        ipa=args.ipa,
        commit=args.commit,
    )
    json_path = Path(args.json)
    json_path.parent.mkdir(parents=True, exist_ok=True)
    json_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    if args.markdown:
        Path(args.markdown).write_text(markdown(report), encoding="utf-8")
    if args.github_output:
        with Path(args.github_output).open("a", encoding="utf-8") as handle:
            handle.write(f"status={report['status']}\n")
            for key, value in report["tests"]["counts"].items():
                handle.write(f"test_{key}={value}\n")
            handle.write(f"test_executed={report['tests']['executed']}\n")
            handle.write(f"device_status={report['device']['status']}\n")

    print(f"Quality report: {report['status']} ({report['tests']['executed']} tests executed)")
    for problem in report["blocked"]:
        print(f"FAIL {problem}")
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
