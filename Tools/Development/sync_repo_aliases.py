#!/usr/bin/env python3
"""Keep canonical repository assets and their published root aliases identical.

The clean root owns canonical files under Resources/ and Services/API/, while a
few stable root paths remain because remote feeds, README images, Render and the
LicensePlist Xcode plugin discover them there. Copies — not symlinks — are used
so raw.githubusercontent.com and macOS checkouts see the actual bytes.
"""
from __future__ import annotations

import argparse
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ALIASES = (
    ("Resources/Branding/icon.png", "icon.png"),
    ("Resources/RepositoryMetadata/app-repo.json", "app-repo.json"),
    ("Resources/RepositoryMetadata/repos.json", "repos.json"),
    ("Resources/Licensing/license_plist.yml", "license_plist.yml"),
    ("Services/API/render.yaml", "render.yaml"),
)


def problems() -> list[str]:
    result: list[str] = []
    for canonical_rel, alias_rel in ALIASES:
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


def sync() -> None:
    for canonical_rel, alias_rel in ALIASES:
        canonical, alias = ROOT / canonical_rel, ROOT / alias_rel
        alias.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(canonical, alias)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help="fail when any alias differs (default)")
    mode.add_argument("--write", action="store_true", help="copy canonical bytes onto root aliases")
    args = parser.parse_args()
    if args.write:
        sync()
        print(f"Repository compatibility aliases: {len(ALIASES)} synchronized")
        return 0
    found = problems()
    if found:
        print("\n".join(found), file=sys.stderr)
        print("Run python3 Tools/Development/sync_repo_aliases.py --write", file=sys.stderr)
        return 1
    print(f"Repository compatibility aliases: {len(ALIASES)} byte-identical")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
