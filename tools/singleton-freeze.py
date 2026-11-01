#!/usr/bin/env python3
"""Freeze the number of global singletons.

The audit counted 54 `static let shared` globals; the tree has 56. Each one is a hidden dependency:
it decides what a view model can be tested with, and it decides what has to be torn down between
tests. Removing them all at once is not a change anyone can review, so this gate does the reviewable
part — the count may go down, never up.

A new singleton is sometimes the right call (a process-wide owner of one hardware queue, say). When
it is, say so in the same commit by raising the number here, deliberately, with a reason in the
commit message. That is the whole rule.

Usage:

    python3 tools/singleton-freeze.py             # check (exit 1 when the count grew)
    python3 tools/singleton-freeze.py --write     # regenerate the baseline after removing one
    python3 tools/singleton-freeze.py --list      # show every file's count

The baseline lives in `tools/singleton-baseline.json`.
"""

import argparse
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCES = ROOT / "VexSign"
BASELINE = ROOT / "tools" / "singleton-baseline.json"

SINGLETON = re.compile(r"\bstatic\s+(?:let|var)\s+shared\b")


def collect():
    """Returns {relative path: [line numbers]} for every `static shared` declaration."""
    found = {}

    for path in sorted(SOURCES.rglob("*.swift")):
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except UnicodeDecodeError:
            continue

        hits = [
            number
            for number, line in enumerate(lines, start=1)
            if SINGLETON.search(line) and not line.lstrip().startswith("//")
        ]
        if hits:
            found[path.relative_to(ROOT).as_posix()] = hits

    return found


def load_baseline():
    if not BASELINE.exists():
        return {}
    return json.loads(BASELINE.read_text(encoding="utf-8"))


def write_baseline(counts):
    BASELINE.write_text(
        json.dumps(dict(sorted(counts.items())), indent=2) + "\n",
        encoding="utf-8",
    )


def main():
    parser = argparse.ArgumentParser(description="Fail when global singletons grow.")
    parser.add_argument("--write", action="store_true", help="regenerate the baseline from the tree")
    parser.add_argument("--list", action="store_true", help="print every file's current count")
    parser.add_argument("--limit", type=int, default=20, help="how many findings to print")
    arguments = parser.parse_args()

    found = collect()
    counts = {path: len(lines) for path, lines in found.items()}
    total = sum(counts.values())

    if arguments.write:
        write_baseline(counts)
        print(f"baseline written: {total} singletons in {len(counts)} files")
        return 0

    if arguments.list:
        for path, count in sorted(counts.items(), key=lambda pair: -pair[1]):
            print(f"{count:4d}  {path}")
        print(f"{total:4d}  total")
        return 0

    baseline = load_baseline()
    grew = {}
    for path, count in counts.items():
        allowed = baseline.get(path, 0)
        if count > allowed:
            grew[path] = (allowed, count)

    removed = sum(max(0, baseline.get(path, 0) - counts.get(path, 0)) for path in baseline)
    baseline_total = sum(baseline.values())

    if not grew:
        print(
            f"✅ {total} singletons across {len(counts)} files — none above the baseline"
            + (f" ({removed} fewer than the baseline, regenerate it with --write)" if removed else "")
        )
        return 0

    print(f"❌ {len(grew)} file(s) added a global singleton (baseline {baseline_total}, now {total}):")
    shown = 0
    for path, (allowed, count) in sorted(grew.items()):
        delta = count - allowed
        print(f"  {path}: {count} (baseline {allowed}, +{delta})")
        for line in found[path][-delta:][: max(0, arguments.limit - shown)]:
            print(f"      line {line}")
            shown += 1
        if shown >= arguments.limit:
            break
    print()
    print("Inject the dependency instead, or raise tools/singleton-baseline.json in the same commit.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
