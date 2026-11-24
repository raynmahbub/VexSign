#!/usr/bin/env python3
"""Turn the strict-concurrency report into a ratchet for first-party code.

The `concurrency` job compiles the first-party packages with
`-strict-concurrency=complete` and prints the diagnostics, but the step carries
`continue-on-error` because a package mid-cleanup can fail the build for reasons that have nothing
to do with this change — so the job has never actually stopped anything. Third-party checkouts
also emit warnings nobody here can fix, and they were mixed into the same pile of text.

This script separates the two: it keeps the diagnostics whose file lives in first-party source,
counts them, and compares that count with a recorded baseline. Fewer is always fine; more fails the
step; an unrecorded (`null`) baseline reports and passes, so the first run after this lands is not
a failure.

    python3 .github/scripts/strict_concurrency_ratchet.py --log run.log \
        --baseline Tools/Validation/repository-validation/strict-concurrency-baseline.json
    python3 .github/scripts/strict_concurrency_ratchet.py --log run.log --baseline ... --update

Exit status: 0 = clean or unchanged, 1 = more first-party diagnostics than the baseline.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

#: `path:line:col: warning: message` (or `error:`), the shape swiftc and SwiftPM both use.
DIAGNOSTIC = re.compile(r"^(?P<path>[^\s:][^:]*\.swift):(?P<line>\d+):(?P<column>\d+):\s*(?P<kind>warning|error):\s*(?P<message>.*)$")

#: Where first-party source lives, mirroring `.swiftformat`'s excludes the other way round.
FIRST_PARTY_PREFIXES = ("App/", "Shared/", "Storage/", "Networking/", "Apple/",
                        "DesignSystem/", "VexSign/Services/", "Tests/",
                        "Packages/NimbleKit/", "Packages/AltSourceKit/",
                        "Packages/NativeSigning/", "Packages/DeviceBridge/")


def first_party(path: str, root: Path) -> bool:
    """Whether a diagnostic belongs to code this repository owns."""
    normalised = path.replace("\\", "/")
    # Absolute paths appear when the package is built outside the checkout root.
    for prefix in FIRST_PARTY_PREFIXES:
        index = normalised.find(prefix)
        if index != -1:
            return True
    try:
        relative = Path(normalised).resolve().relative_to(root).as_posix()
    except (OSError, ValueError):
        return False
    return any(relative.startswith(prefix) for prefix in FIRST_PARTY_PREFIXES)


def repo_relative(path: str) -> str:
    """Strip the checkout prefix from an absolute diagnostic path."""
    parts = path.replace("\\", "/").lstrip("/").split("/")
    for index, part in enumerate(parts):
        candidate = "/".join(parts[index:])
        if candidate.startswith(FIRST_PARTY_PREFIXES):
            return candidate
    return "/".join(parts)


def collect(log: str, root: Path) -> list[dict[str, str]]:
    """Every first-party diagnostic in the log, in the order the compiler emitted it."""
    found = []
    for line in log.splitlines():
        match = DIAGNOSTIC.match(line.strip())
        if not match:
            continue
        if not first_party(match.group("path"), root):
            continue
        found.append({
            "file": repo_relative(match.group("path")),
            "line": match.group("line"),
            "kind": match.group("kind"),
            "message": match.group("message").strip(),
        })
    return found


def load_baseline(path: Path) -> int | None:
    if not path.exists():
        return None
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    count = payload.get("count") if isinstance(payload, dict) else None
    return int(count) if isinstance(count, int) else None


def write_baseline(path: Path, count: int) -> None:
    payload = {
        "count": count,
        "recordedAt": datetime.now(timezone.utc).strftime("%Y-%m-%d"),
        "note": "First-party strict-concurrency diagnostics. Recorded from a real run; update only when you have removed some, not to make a red run green.",
    }
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def render_summary(diagnostics: list[dict[str, str]], baseline: int | None, limit: int = 20) -> str:
    lines = ["### Strict concurrency (first-party)", ""]
    if not diagnostics:
        lines.append("No first-party diagnostics in this log.")
    else:
        lines.append(f"**{len(diagnostics)}** first-party diagnostic(s).")
        if baseline is None:
            lines.append("_No baseline recorded yet._ Record it with `--update` after reading a real run.")
        else:
            delta = len(diagnostics) - baseline
            lines.append(f"Baseline: **{baseline}** → **{delta:+d}** with this change.")
        lines += ["", "| File | Line | Kind | Message |", "| --- | ---: | --- | --- |"]
        for entry in diagnostics[:limit]:
            message = entry["message"].replace("|", "\\|")
            lines.append(f"| `{entry['file']}` | {entry['line']} | {entry['kind']} | {message} |")
        if len(diagnostics) > limit:
            lines.append(f"| _and {len(diagnostics) - limit} more_ | | | |")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--log", required=True, type=Path)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--summary", type=Path, default=None,
                        help="append the markdown summary here (a CI step summary)")
    parser.add_argument("--update", action="store_true", help="record the measured count")
    arguments = parser.parse_args()

    log = arguments.log.read_text(encoding="utf-8", errors="replace") if arguments.log.exists() else ""
    diagnostics = collect(log, arguments.root)
    baseline = load_baseline(arguments.baseline)
    summary = render_summary(diagnostics, baseline)
    print(summary)
    if arguments.summary:
        with open(arguments.summary, "a", encoding="utf-8") as handle:
            handle.write(summary + "\n")
    if arguments.update:
        write_baseline(arguments.baseline, len(diagnostics))
        print(f"recorded baseline {len(diagnostics)} in {arguments.baseline}")
        return 0
    if baseline is None:
        print("::warning::No first-party strict-concurrency baseline recorded yet; reporting only.")
        return 0
    if len(diagnostics) > baseline:
        print(f"::error::First-party strict-concurrency diagnostics grew from {baseline} to "
              f"{len(diagnostics)}. Fix the new ones, or record a deliberate change with --update.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
