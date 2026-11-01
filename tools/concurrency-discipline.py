#!/usr/bin/env python3
"""Keep concurrency escapes from spreading (VX-15).

`@unchecked Sendable`, `nonisolated(unsafe)` and `@preconcurrency import` are all the same trade:
the compiler stops checking something, and nobody notices when the assumption later becomes false.
Each one is legitimate occasionally — a type that really is thread-safe without the compiler being
able to prove it — but they must be a decision, not a habit.

The rule: **the count per file may not grow.** Removing one is welcome and shrinks the baseline.

Usage:

    python3 tools/concurrency-discipline.py             # check (exit 1 on growth)
    python3 tools/concurrency-discipline.py --write     # regenerate the baseline
    python3 tools/concurrency-discipline.py --list      # every file's count, with the pattern

The baseline lives in `tools/concurrency-baseline.json`.

What this does *not* do is prove anything about isolation. It is deliberately a counting gate, run
wherever there is no compiler; `make strict-concurrency` is the check that actually compiles the
leaf package with `StrictConcurrency` and prints the warnings.
"""

import argparse
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCES = ROOT / "VexSign"
BASELINE = ROOT / "tools" / "concurrency-baseline.json"

PATTERNS = {
    "unchecked-sendable": re.compile(r"@unchecked\s+Sendable"),
    "nonisolated-unsafe": re.compile(r"nonisolated\(unsafe\)"),
    "preconcurrency": re.compile(r"@preconcurrency\b"),
}


def collect():
    """Returns {relative path: [(line number, pattern name)]}."""
    found = {}

    for path in sorted(SOURCES.rglob("*.swift")):
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except UnicodeDecodeError:
            continue

        hits = []
        for number, line in enumerate(lines, start=1):
            stripped = line.lstrip()
            if stripped.startswith("//"):
                continue
            for name, pattern in PATTERNS.items():
                if pattern.search(line):
                    hits.append((number, name))
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
    parser = argparse.ArgumentParser(description="Fail when concurrency escapes grow.")
    parser.add_argument("--write", action="store_true", help="regenerate the baseline from the tree")
    parser.add_argument("--list", action="store_true", help="print every file's current count")
    parser.add_argument("--limit", type=int, default=20, help="how many findings to print")
    arguments = parser.parse_args()

    found = collect()
    counts = {path: len(hits) for path, hits in found.items()}
    total = sum(counts.values())

    if arguments.write:
        write_baseline(counts)
        print(f"baseline written: {total} concurrency escapes in {len(counts)} files")
        return 0

    if arguments.list:
        for path, hits in sorted(found.items(), key=lambda pair: -len(pair[1])):
            kinds = ", ".join(sorted({name for _, name in hits}))
            print(f"{len(hits):4d}  {path}  ({kinds})")
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
            f"✅ {total} concurrency escapes across {len(counts)} files — none above the baseline"
            + (f" ({removed} fewer than the baseline, regenerate it with --write)" if removed else "")
        )
        return 0

    print(f"❌ {len(grew)} file(s) added a concurrency escape:")
    shown = 0
    for path, (allowed, count) in sorted(grew.items()):
        delta = count - allowed
        print(f"  {path}: {count} (baseline {allowed}, +{delta})")
        for number, name in found[path][-delta:][: max(0, arguments.limit - shown)]:
            print(f"      line {number}: {name}")
            shown += 1
        if shown >= arguments.limit:
            break
    print()
    print("Isolate the state instead (@MainActor, an actor, a Sendable value type), or raise")
    print("tools/concurrency-baseline.json in the same commit with the reason.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
