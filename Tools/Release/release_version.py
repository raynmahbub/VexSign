#!/usr/bin/env python3
"""Semantic version and release-tag helpers shared by the release gates.

The app's marketing version is SemVer-like (`MAJOR.MINOR[.PATCH][-pre]`).
Apple's CFBundleVersion is numeric and independent; `build_number()` below
preserves the repository's existing commit-count scheme rather than inventing a
new versioning policy.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

VERSION_RE = re.compile(r"^(0|[1-9]\d*)\.(0|[1-9]\d*)(?:\.(0|[1-9]\d*))?(?:-([0-9A-Za-z.-]+))?$")
TAG_RE = re.compile(r"^v" + VERSION_RE.pattern[1:-1] + r"$")
NUMERIC_BUILD_RE = re.compile(r"^[0-9]+(?:\.[0-9]+)*$")


@dataclass(frozen=True, order=True)
class ReleaseVersion:
    major: int
    minor: int
    patch: int
    prerelease: str = ""

    @property
    def base(self) -> str:
        return f"{self.major}.{self.minor}.{self.patch}"

    def __str__(self) -> str:
        return self.base + (f"-{self.prerelease}" if self.prerelease else "")


def parse_version(value: str) -> ReleaseVersion:
    if not isinstance(value, str):
        raise ValueError(f"Invalid version: {value!r}")
    match = VERSION_RE.fullmatch(value)
    if not match:
        raise ValueError(f"Invalid semantic version: {value!r}")
    return ReleaseVersion(
        int(match.group(1)), int(match.group(2)), int(match.group(3) or 0), match.group(4) or ""
    )


def parse_tag(tag: str) -> ReleaseVersion:
    """Accept v1.2, v1.2.0, and v1.2.0-beta.1; reject every other ref."""
    if not isinstance(tag, str) or not TAG_RE.fullmatch(tag):
        raise ValueError(f"Invalid release tag: {tag!r} (expected v<semver>)")
    return parse_version(tag[1:])


def project_version_for_tag(tag: str) -> str:
    """The Xcode marketing version is the base version, never the tag suffix."""
    return parse_tag(tag).base


def is_prerelease(version: ReleaseVersion | str) -> bool:
    if isinstance(version, str):
        parsed = parse_tag(version) if version.startswith("v") else parse_version(version)
    else:
        parsed = version
    return bool(parsed.prerelease)


def validate_numeric_build(value: str) -> str:
    if not isinstance(value, str) or not NUMERIC_BUILD_RE.fullmatch(value):
        raise ValueError(f"Invalid CFBundleVersion: {value!r}")
    return value


def build_number(commit_count: int) -> str:
    """Preserve the repository's existing, Apple-compatible commit-count build."""
    if not 1 <= commit_count <= 99989999:
        raise ValueError("Commit count is outside the supported build-version range")
    return f"{1 + commit_count // 10000}.{commit_count // 100 % 100}.{commit_count % 100}"


def assert_tag_matches(tag: str, marketing_version: str) -> None:
    if is_prerelease(tag) and parse_tag(tag).base != parse_version(marketing_version).base:
        raise ValueError(f"Tag {tag} does not match marketing version {marketing_version}")
    if not is_prerelease(tag) and str(parse_tag(tag)) != str(parse_version(marketing_version).base):
        raise ValueError(f"Tag {tag} does not match marketing version {marketing_version}")


def main() -> None:
    import argparse

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version", help="semantic version or v-prefixed release tag")
    parser.add_argument("--base-only", action="store_true", help="print only MAJOR.MINOR.PATCH")
    args = parser.parse_args()
    parsed = parse_tag(args.version) if args.version.startswith("v") else parse_version(args.version)
    print(parsed.base if args.base_only else parsed)


if __name__ == "__main__":
    main()
