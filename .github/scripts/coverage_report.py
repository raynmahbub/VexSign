#!/usr/bin/env python3
"""Turn an xcresult bundle into a coverage summary a human can act on.

The simulator suite has grown to ~70 files, but nothing said which code it
actually reaches. With `codeCoverageEnabled` on the VexSignTests scheme, the
xcresult carries per-file line coverage; this reads it with `xccov`, prints the
overall number plus the least-covered first-party files, and appends a Markdown
table to the job summary.

Reporting and a floor. The number is printed, summarised and uploaded either way; the
`--fail-under` floor only has to catch a collapse, not rank the suite — a threshold picked to
be "about right" would turn every unrelated pull request red the first time it was missed, and
would be raised by guesswork. Use the least-covered list to target tests (and the
`try?`/singleton burn-down) instead of guessing.

The floor is separate from "no data": `--github-output` publishes the percentage and a
`floor` status, so CI can keep the report step tolerant of a missing xccov while a second step
fails the job when a real number is below the floor.

A *missing* report is different from a low one. When `xccov` cannot read the
bundle this exits 1 with xccov's own message: the CI step tolerates that failure
(`continue-on-error`) but shows it, because a coverage pipeline that silently
reports nothing is worse than one that is honestly broken.

Usage (macOS, after xcodebuild test):
    python3 .github/scripts/coverage_report.py --result-bundle path/to.xcresult
    python3 .github/scripts/coverage_report.py --result-bundle path/to.xcresult \\
        --fail-under 20 --github-output "$GITHUB_OUTPUT"
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
FIRST_PARTY_PREFIXES = ("VexSign/App/iOS/",)
EXCLUDE_MARKERS = ("/SourcePackages/", "/Checkouts/", "VexSignTests", ".xctest")


class CoverageUnavailable(RuntimeError):
    """`xccov` could not read the bundle. Carries its stderr, not just the command."""


def xccov_json(result_bundle: Path) -> dict:
    completed = subprocess.run(
        ["xcrun", "xccov", "view", "--report", "--json", str(result_bundle)],
        capture_output=True, text=True,
    )
    if completed.returncode != 0:
        # `check=True` raised a CalledProcessError whose str() is the *command*, so the
        # CI annotation said "returned non-zero exit status 1" and hid the reason
        # ("no coverage data", "not a result bundle", …) that xccov had printed.
        detail = (completed.stderr or completed.stdout or "").strip().splitlines()
        raise CoverageUnavailable(detail[0] if detail else f"xccov exited {completed.returncode}")
    try:
        return json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        raise CoverageUnavailable(f"xccov printed no JSON: {error}") from error


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
                "name": name.split("VexSign/App/iOS/")[-1] if "VexSign/App/iOS/" in name else name,
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


def floor_status(percent: float, fail_under: float | None) -> str:
    """`below_floor`, `at_floor` or `ok` for a measured percentage.

    `at_floor` is the band within two points above the floor: still passing, but worth an
    annotation before the next change is the one that drops it.
    """
    if fail_under is None:
        return "ok"
    if percent < fail_under:
        return "below_floor"
    if percent < fail_under + 2:
        return "at_floor"
    return "ok"


def _write_github_output(destination, values: dict[str, str]) -> None:
    if destination is None:
        return
    with open(destination, "a", encoding="utf-8") as handle:
        for key, value in values.items():
            handle.write(f"{key}={value}\n")


def _write_unavailable(destination, reason: str) -> None:
    """Records *why* there is no coverage, so the artifact is never an empty file."""
    if destination is None:
        return
    destination.write_text(
        json.dumps({"coverageAvailable": False, "error": reason}, indent=2),
        encoding="utf-8",
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--result-bundle", required=True, type=Path)
    parser.add_argument("--limit", type=int, default=20)
    parser.add_argument("--json", type=Path, help="also write the raw xccov report here")
    parser.add_argument(
        "--fail-under", type=float, default=None, metavar="PERCENT",
        help="exit 2 when line coverage is below this percentage",
    )
    parser.add_argument(
        "--github-output", type=Path, default=None,
        help="append percent/floor/status lines to this file (a CI output file)",
    )
    arguments = parser.parse_args()

    if not arguments.result_bundle.exists():
        print(f"::warning::No xcresult bundle at {arguments.result_bundle}; skipping coverage report.")
        _write_unavailable(arguments.json, f"no xcresult at {arguments.result_bundle}")
        return 0

    try:
        report = xccov_json(arguments.result_bundle)
    except (CoverageUnavailable, FileNotFoundError) as error:
        # Still not a build failure — the CI step is `continue-on-error` — but it must
        # not look like success either. Returning non-zero turns the step orange, and
        # the JSON keeps the reason in the uploaded artifact instead of an empty file.
        print(f"::warning::Coverage unavailable: {error}")
        _write_unavailable(arguments.json, str(error))
        return 1

    percent, covered, executable, files = summarise(report, arguments.limit)
    markdown = render_markdown(percent, covered, executable, files)
    print(markdown)

    status = floor_status(percent, arguments.fail_under)
    _write_github_output(arguments.github_output, {
        "percent": f"{percent:.1f}",
        "floor": f"{arguments.fail_under:.1f}" if arguments.fail_under is not None else "",
        "floor_status": status,
    })
    if status == "below_floor":
        print(
            f"::error::Line coverage {percent:.1f}% is below the {arguments.fail_under:.1f}% floor. "
            "Add tests for the paths this change touched, or lower the floor deliberately in .github/workflows/ci.yml."
        )
    elif status == "at_floor":
        print(
            f"::warning::Line coverage {percent:.1f}% is within two points of the "
            f"{arguments.fail_under:.1f}% floor."
        )

    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write(markdown + "\n")
    if arguments.json:
        arguments.json.write_text(json.dumps(report, indent=2), encoding="utf-8")
    # Exit 1 means "no coverage to read" and is tolerated by the CI step; exit 2 means the
    # suite ran, produced a number, and it is below the floor, which is not.
    return 2 if status == "below_floor" else 0


if __name__ == "__main__":
    sys.exit(main())
