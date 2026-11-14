#!/usr/bin/env python3
"""Report whether the Xcode project's SwiftPM requirements are behind upstream.

Dependabot understands Package.swift, but VexSign's app dependencies live in
project.pbxproj, which it does not parse. This read-only audit gives those
packages the same visibility without guessing at an unsafe automatic bump.

Usage:
    python3 Tools/CI/check-xcode-packages.py
    python3 Tools/CI/check-xcode-packages.py --format markdown
    python3 Tools/CI/check-xcode-packages.py --fail-on-outdated

Exit status is 0 unless --fail-on-outdated is given and an update candidate
exists. Exact pins require a deliberate requirement change, not an automatic update. Network/API failures are reported as "unknown", not outdated.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PBX = ROOT / "VexSign.xcodeproj" / "project.pbxproj"
BLOCK = re.compile(
    r'([0-9A-F]{24}) /\* XCRemoteSwiftPackageReference "([^"]+)" \*/ = \{(.*?)\n\t\t\};',
    re.S,
)
SEMVER = re.compile(r"^v?(\d+)\.(\d+)\.(\d+)(?:[-+].*)?$")
STABLE = re.compile(r"^v?(\d+)\.(\d+)\.(\d+)$")


@dataclass
class Requirement:
    name: str
    repository: str
    kind: str
    declared: str
    block: str
    latest: str | None = None
    compatible: str | None = None
    error: str | None = None


def parse_version(text: str) -> tuple[int, int, int] | None:
    match = SEMVER.match(text.strip())
    return tuple(int(part) for part in match.groups()) if match else None  # type: ignore[return-value]


def requirements() -> list[Requirement]:
    text = PBX.read_text()
    found: list[Requirement] = []
    for match in BLOCK.finditer(text):
        body = match.group(3)
        repo = re.search(r'repositoryURL = "([^"]+)"', body)
        kind = re.search(r"kind = (\w+);", body)
        version = re.search(r"(?:version|minimumVersion) = ([^;]+);", body)
        if not repo or not kind or not version:
            continue
        found.append(Requirement(
            name=match.group(2),
            repository=repo.group(1).removesuffix(".git"),
            kind=kind.group(1),
            declared=version.group(1).strip(),
            block=match.group(0),
        ))
    return found


def github_json(url: str) -> object:
    request = urllib.request.Request(url, headers={
        "Accept": "application/vnd.github+json",
        "User-Agent": "VexSign dependency audit",
    })
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(request, timeout=20) as response:
        return json.load(response)


def remote_versions(repo: str) -> list[str]:
    owner, name = repo.rstrip("/").split("/")[-2:]
    tags: list[str] = []
    try:
        releases = github_json(f"https://api.github.com/repos/{owner}/{name}/releases?per_page=100")
        tags.extend(
            release["tag_name"]
            for release in releases
            if isinstance(release, dict) and release.get("prerelease") is not True
        )
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, ValueError):
        pass
    try:
        entries = github_json(f"https://api.github.com/repos/{owner}/{name}/tags?per_page=100")
        tags.extend(entry["name"] for entry in entries if isinstance(entry, dict))
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, ValueError):
        pass
    return sorted({tag for tag in tags if STABLE.match(tag)}, key=parse_version, reverse=True)


def choose(req: Requirement, versions: list[str]) -> str | None:
    current = parse_version(req.declared)
    if current is None:
        return None
    for candidate in versions:
        parsed = parse_version(candidate)
        if parsed is None or parsed < current:
            continue
        if req.kind == "exactVersion" and parsed == current:
            return candidate
        if req.kind == "upToNextMajorVersion" and parsed[0] == current[0]:
            return candidate
        if req.kind == "upToNextMinorVersion" and parsed[:2] == current[:2]:
            return candidate
    return None


def has_update(req: Requirement) -> bool:
    # Exact pins require an explicit requirement change; latest is only a candidate.
    candidate = req.latest if req.kind == "exactVersion" else req.compatible
    declared = parse_version(req.declared)
    version = parse_version(candidate) if candidate else None
    return declared is not None and version is not None and version > declared


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--format", choices=("text", "markdown"), default="text")
    parser.add_argument("--fail-on-outdated", action="store_true")
    args = parser.parse_args()

    rows = requirements()
    if not rows:
        print("No Xcode SwiftPM requirements found; check the pbxproj parser.", file=sys.stderr)
        return 1

    for req in rows:
        try:
            versions = remote_versions(req.repository)
            req.latest = versions[0] if versions else None
            req.compatible = choose(req, versions)
        except Exception as error:  # Network failures must not fail the build.
            req.error = str(error)

    outdated = [req for req in rows if has_update(req)]

    if args.format == "markdown":
        print("| Package | Rule | Declared | Latest | Newest compatible |")
        print("| --- | --- | --- | --- | --- |")
        for req in rows:
            latest = req.latest or ("unknown" if req.error else "none")
            compatible = req.compatible or "-"
            print(f"| `{req.name}` | `{req.kind}` | `{req.declared}` | `{latest}` | `{compatible}` |")
        if outdated:
            print("\n> Update candidates require review and macOS build/testing; exact pins require a deliberate requirement change. “Compatible” means the version satisfies the declared rule, not that it has been tested.")
    else:
        for req in rows:
            latest = req.latest or ("unknown" if req.error else "none")
            marker = "  update" if req in outdated else ""
            print(f"{req.name:24} {req.kind:24} {req.declared:12} latest={latest:12}{marker}")
            if req.error:
                print(f"  ! {req.error}", file=sys.stderr)

    if args.fail_on_outdated and outdated:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
