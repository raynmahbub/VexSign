#!/usr/bin/env python3
"""Keep canonical repository assets and their published root aliases identical.

The app feed retains its published root alias; other assets and configuration
live only in their canonical folders. Copies, not symlinks, let raw GitHub URLs
serve the feed bytes directly.

`MIRRORED` covers a different kind of duplicate: files Xcode writes in two places
for two entry points (`VexSign.xcodeproj` and `VexSign.xcworkspace`). Neither is
derived from the other, so they drift silently — one `swift package resolve` from
the project and one from the workspace can leave the two entry points pinning
different revisions, which resolves differently depending on how the repository
was opened. Checking them here makes that drift fail a gate instead of a build.
"""
from __future__ import annotations

import argparse
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
ALIASES = (
    ("VexSign/Resources/Templates/app-repo.json", "app-repo.json"),
)


MIRRORED = (
    (
        "VexSign.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
        "VexSign.xcworkspace/xcshareddata/swiftpm/Package.resolved",
    ),
)


def problems() -> list[str]:
    result: list[str] = []
    for canonical_rel, alias_rel in ALIASES + MIRRORED:
        canonical, alias = ROOT / canonical_rel, ROOT / alias_rel
        if not canonical.is_file():
            result.append(f"missing canonical file: {canonical_rel}")
            continue
        if not alias.is_file():
            result.append(f"missing root compatibility alias: {alias_rel}")
            continue
        if canonical.read_bytes() != alias.read_bytes():
            result.append(f"alias drift: {alias_rel} differs from {canonical_rel}")
    return result


def _atomic_copy(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    tmp = destination.with_name(f".{destination.name}.tmp")
    shutil.copy2(source, tmp)
    tmp.replace(destination)


def sync() -> None:
    for canonical_rel, alias_rel in ALIASES:
        canonical, alias = ROOT / canonical_rel, ROOT / alias_rel
        if not canonical.is_file():
            raise FileNotFoundError(f"missing canonical file: {canonical_rel}")
        _atomic_copy(canonical, alias)

    for first_rel, second_rel in MIRRORED:
        first, second = ROOT / first_rel, ROOT / second_rel
        if not first.is_file() and not second.is_file():
            raise FileNotFoundError(f"missing mirrored files: {first_rel}, {second_rel}")
        # Neither Xcode entry point is derived from the other: when both are non-empty
        # and differ, propagate the newer resolution file rather than clobbering it.
        if (
            second.is_file()
            and second.stat().st_size > 0
            and (not first.is_file() or first.stat().st_size == 0 or second.stat().st_mtime_ns > first.stat().st_mtime_ns)
        ):
            _atomic_copy(second, first)
        else:
            _atomic_copy(first, second)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help="fail when any alias differs (default)")
    mode.add_argument("--write", action="store_true", help="copy canonical bytes onto root aliases")
    args = parser.parse_args()
    if args.write:
        sync()
        print(f"Repository compatibility aliases: {len(ALIASES)} synchronized")
        print(f"Mirrored Xcode resolution files: {len(MIRRORED)} synchronized")
        return 0
    found = problems()
    if found:
        print("\n".join(found), file=sys.stderr)
        print("Run python3 Tools/Validation/repository-validation/sync_repo_aliases.py --write", file=sys.stderr)
        return 1
    print(f"Repository compatibility aliases: {len(ALIASES)} byte-identical")
    print(f"Mirrored Xcode resolution files: {len(MIRRORED)} byte-identical")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
