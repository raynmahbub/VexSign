#!/usr/bin/env python3
"""Combine unit, UI, build and device evidence into one honest summary.

Each underlying job keeps its own gate. This script never upgrades a skipped or
missing result into a pass; it reads the actual reports and artifact bundles
produced by those jobs and names what is still blocked.
"""

from __future__ import annotations

import argparse
import json
import re
from datetime import datetime, timezone
from pathlib import Path

ATTACHMENT_HINT = re.compile(r"attachment", re.IGNORECASE)


def load_json(path):
    if not path or not Path(path).is_file():
        return None
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None


def find_json(root, *names):
    if not root or not Path(root).is_dir():
        return None
    for name in names:
        for path in sorted(Path(root).rglob(name)):
            return path
    return None


def count_attachments(payload):
    """Count attachment records in an xcresult test-results JSON tree."""
    if not isinstance(payload, (dict, list)):
        return 0
    if isinstance(payload, dict):
        count = 0 if ATTACHMENT_HINT.search(str(payload.get("type", "")) or "") else 0
        if isinstance(payload.get("attachments"), list):
            count += len(payload["attachments"])
        for value in payload.values():
            count += count_attachments(value)
        return count
    return sum(count_attachments(item) for item in payload)


def test_section(label, report, results):
    if not isinstance(report, dict):
        return [f"## {label}", "", "- Status: **BLOCKED** — no quality report artifact", ""], True
    tests = report.get("tests") if isinstance(report.get("tests"), dict) else {}
    counts = tests.get("counts") if isinstance(tests, dict) else {}
    executed = tests.get("executed", 0)
    failed = report.get("status") != "passed"
    lines = [
        f"## {label}", "",
        f"- Status: **{str(report.get('status', 'unknown')).upper()}**",
        f"- Executed: {executed}",
        f"- Passed: {counts.get('passed', 0)} · Failed: {counts.get('failed', 0)} · Skipped: {counts.get('skipped', 0)}",
        f"- Crash signals: {len(report.get('crash_signals') or [])}",
        f"- Screenshot/attachment records in xcresult JSON: {count_attachments(results)}",
    ]
    blocked = report.get("blocked") or []
    if blocked:
        lines.extend(["", "- Blocked: " + "; ".join(str(item) for item in blocked[:5])])
    lines.append("")
    return lines, failed


def build(artifacts, jobs):
    artifacts = Path(artifacts) if artifacts else None
    unit = load_json(find_json(artifacts, "quality-report.json"))
    ui = load_json(find_json(artifacts, "ui-quality-report.json"))
    unit_results = load_json(find_json(artifacts, "test-results.json", "quality-report-test-results.json"))
    ui_results = load_json(find_json(artifacts, "ui-test-results.json"))
    coverage = load_json(find_json(artifacts, "coverage.json"))
    device = load_json(find_json(artifacts, "feature-acceptance.json"))

    lines = [
        "# Consolidated QA evidence", "",
        f"_Generated {datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}_", "",
        "## Job conclusions", "",
    ]
    failed = False
    for name, result in sorted(jobs.items()):
        lines.append(f"- `{name}`: {result}")
        if result in ("failure", "cancelled", "timed_out"):
            failed = True

    unit_lines, unit_failed = test_section("Unit / integration tests", unit, unit_results)
    ui_lines, ui_failed = test_section("Simulator UI tests (XCUITest)", ui, ui_results)
    lines.extend(unit_lines)
    lines.extend(ui_lines)
    failed = failed or unit_failed or ui_failed

    lines.extend(["## Build and coverage", ""])
    build_job = jobs.get("build", "unknown")
    lines.append(f"- Debug/Release build and analyzer: {build_job}")
    if build_job not in ("success",):
        failed = True
    if isinstance(coverage, dict):
        lines.append(f"- Line coverage: {coverage.get('percent', 'unknown')}%")
    else:
        lines.append("- Line coverage: **BLOCKED** — no coverage artifact")

    lines.extend(["", "## Physical-device evidence", ""])
    if isinstance(device, dict):
        cases = device.get("cases") if isinstance(device.get("cases"), dict) else {}
        statuses = {}
        for case in cases.values():
            status = case.get("result", "invalid") if isinstance(case, dict) else "invalid"
            statuses[status] = statuses.get(status, 0) + 1
        lines.append(f"- Cases: {json.dumps(statuses, sort_keys=True)}")
        lines.append(f"- Source commit: {device.get('source_commit', 'missing')}")
    else:
        lines.append("- **BLOCKED** — no device report. A simulator pass is not hardware evidence.")

    lines.extend([
        "", "## Honest limits", "",
        "- A report is not a test run. Only executed leaf results from the xcresult count.",
        "- Screenshots are attached inside the uploaded xcresult, not invented here.",
        "- Device cases stay blocked until a named tester fills them from real hardware.",
        "",
    ])
    return {"status": "failed" if failed else "passed", "jobs": jobs,
            "unit": unit, "ui": ui, "device": device, "coverage": coverage}, "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifacts", help="Directory containing downloaded CI artifacts")
    parser.add_argument("--job", action="append", default=[], metavar="NAME=RESULT")
    parser.add_argument("--json", required=True)
    parser.add_argument("--markdown", required=True)
    parser.add_argument("--github-output")
    args = parser.parse_args()

    jobs = {}
    for entry in args.job:
        if "=" in entry:
            name, result = entry.split("=", 1)
            jobs[name] = result

    report, markdown_text = build(args.artifacts, jobs)
    for path, text in ((args.json, json.dumps(report, indent=2) + "\n"), (args.markdown, markdown_text)):
        target = Path(path)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")
    if args.github_output:
        with Path(args.github_output).open("a", encoding="utf-8") as handle:
            handle.write(f"status={report['status']}\n")
    print(f"Combined report: {report['status']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
