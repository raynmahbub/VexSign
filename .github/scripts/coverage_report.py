#!/usr/bin/env python3
"""Turn an xcresult bundle into a coverage summary a human can act on.

The simulator suite has grown to ~70 files, but nothing said which code it
actually reaches. With `codeCoverageEnabled` on the VexSignTests scheme, the
xcresult carries per-file line coverage; this reads it with `xccov`, prints the
overall number plus the least-covered first-party files, and appends a Markdown
table to the job summary.

Reporting only: a low number never fails the job. Use the least-covered list to
target tests (and the `try?`/singleton burn-down) instead of guessing.

Usage (macOS, after xcodebuild test):
    python3 .github/scripts/coverage_report.py --result-bundle path/to.xcresult
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

# Only first-party app code is interesting; dependencies and the test bundle
# itself would dominate the "least covered" list otherwise.
FIRST_PARTY_PREFIXES = ("App/iOS/VexSign/",)
EXCLUDE_MARKERS = ("/SourcePackages/", "/Checkouts/", "VexSignTests", ".xctest")


def xccov_json(result_bundle: Path) -> dict:
    completed = subprocess.run(
        ["xcrun", "xccov", "view", "--report", "--json", str(result_bundle)],
        capture_output=True, text=True, check=True,
    )
    return json.loads(completed.stdout)


def is_first_party(name: str) -> bool:
    if any(marker in name for marker in EXCLUDE_MARKERS):
        return False
    # xccov reports absolute paths on the runner; match on the path component.
    return any(prefix in name for prefix in FIRST_PARTY_PREFIXES) and name.endswith(".swift")


def summarise(report: dict, limit: int = 20) -> tuple[float, int, int, list[dict]]:
    """Returns (percent, covered, executable, least-covered first-party files)."""
    covered = int(report.get("coveredLines", 0))
    executable = int(report.get("executableLines", 0))
    percent = float(report.get("lineCoverage", 0.0)) * 100.0

    files = []
    for target in report.get("targets", []):
        for file_report in target.get("files", []):
            name = file_report.get("path", file_report.get("name", ""))
            if not is_first_party(name):
                continue
            lines = int(file_report.get("executableLines", 0))
            if lines == 0:
                continue
            files.append({
                "name": name.split("App/iOS/VexSign/")[-1] if "App/iOS/VexSign/" in name else name,
                "covered": int(file_report.get("coveredLines", 0)),
                "executable": lines,
                "percent": float(file_report.get("lineCoverage", 0.0)) * 100.0,
            })
    files.sort(key=lambda entry: (entry["percent"], -entry["executable"]))
    return percent, covered, executable, files[:limit]


def render_markdown(percent: float, covered: int, executable: int, files: list[dict]) -> str:
    lines = [
        "### Test coverage",
        "",
        f"**{percent:.1f}%** of executable lines ({covered}/{executable}).",
        "",
        "Least-covered first-party files — target these when adding regression tests:",
        "",
        "| File | Coverage | Covered / Executable |",
        "| --- | ---: | ---: |",
    ]
    for entry in files:
        lines.append(f"| `{entry['name']}` | {entry['percent']:.1f}% | {entry['covered']}/{entry['executable']} |")
    if not files:
        lines.append("| _no first-party coverage data_ | — | — |")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--result-bundle", required=True, type=Path)
    parser.add_argument("--limit", type=int, default=20)
    parser.add_argument("--json", type=Path, help="also write the raw xccov report here")
    arguments = parser.parse_args()

    if not arguments.result_bundle.exists():
        print(f"::warning::No xcresult bundle at {arguments.result_bundle}; skipping coverage report.")
        return 0

    try:
        report = xccov_json(arguments.result_bundle)
    except (subprocess.CalledProcessError, FileNotFoundError, json.JSONDecodeError) as error:
        # Coverage is a diagnostic. Never turn a green test run red over it.
        print(f"::warning::Could not read coverage ({error}); skipping.")
        return 0

    percent, covered, executable, files = summarise(report, arguments.limit)
    markdown = render_markdown(percent, covered, executable, files)
    print(markdown)

    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write(markdown + "\n")
    if arguments.json:
        arguments.json.write_text(json.dumps(report, indent=2), encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
