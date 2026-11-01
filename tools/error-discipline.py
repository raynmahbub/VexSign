#!/usr/bin/env python3
"""Keep silent `try?` from spreading.

A `try?` throws the failure away. Most of the 400 sites in this app are deliberate — a best-effort
cache write, a file that may not exist — but the ones at a user-visible boundary (a plist write, a
keychain write, a backup, a journal) turn a real failure into silence: the sheet closes, the file is
not there, and nothing in the log says why.

The rule this script enforces is not "no `try?`". It is: **the count of unjustified `try?` per file
may not grow.** New code that genuinely wants to ignore an error can say so where it happens:

    try? cache.remove(at: url) // try? ok: best effort, re-fetched on next launch

Usage:

    python3 tools/error-discipline.py             # check (exit 1 on a new unjustified try?)
    python3 tools/error-discipline.py --write     # regenerate the baseline
    python3 tools/error-discipline.py --list      # show every file's current count

The baseline lives in `tools/error-discipline-baseline.json`. Lowering a file's number after a fix is
welcome and shows up as a smaller baseline in the diff; raising one has to be a deliberate edit.
"""

import argparse
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCES = ROOT / "VexSign"
BASELINE = ROOT / "tools" / "error-discipline-baseline.json"

OCCURRENCE = re.compile(r"\btry\?")
JUSTIFIED = re.compile(r"try\?\s*ok\s*:", re.IGNORECASE)


def collect():
    """Returns {relative path: [line numbers of unjustified `try?`]}."""
    found = {}

    for path in sorted(SOURCES.rglob("*.swift")):
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except UnicodeDecodeError:
            continue

        unjustified = []
        for number, line in enumerate(lines, start=1):
            if not OCCURRENCE.search(line) or JUSTIFIED.search(line):
                continue
            unjustified.append(number)

        if unjustified:
            found[path.relative_to(ROOT).as_posix()] = unjustified

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
    parser = argparse.ArgumentParser(description="Fail when unjustified `try?` sites grow.")
    parser.add_argument("--write", action="store_true", help="regenerate the baseline from the tree")
    parser.add_argument("--list", action="store_true", help="print every file's current count")
    parser.add_argument("--limit", type=int, default=20, help="how many findings to print")
    arguments = parser.parse_args()

    found = collect()
    counts = {path: len(lines) for path, lines in found.items()}
    total = sum(counts.values())

    if arguments.write:
        write_baseline(counts)
        print(f"baseline written: {total} unjustified try? in {len(counts)} files")
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

    if not grew:
        print(
            f"✅ {total} unjustified try? across {len(counts)} files — none above the baseline"
            + (f" ({removed} fewer than the baseline, regenerate it with --write)" if removed else "")
        )
        return 0

    print(f"❌ {len(grew)} file(s) added an unjustified `try?`:")
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
    print("Either handle the error (do/catch + log) or justify it on the line: // try? ok: <reason>")
    return 1


if __name__ == "__main__":
    sys.exit(main())
