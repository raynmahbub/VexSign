#!/usr/bin/env python3
"""Create a secret-free, machine-readable manifest for a built IPA.

The manifest describes what was built and *how far validation went*. It never
claims device installability: a GitHub-hosted runner produces an ad-hoc signed
artifact that a user must re-sign, and this module records that boundary.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import plistlib
import re
import zipfile
from datetime import datetime, timezone
from pathlib import Path

from release_version import TAG_RE, parse_tag, parse_version, validate_numeric_build

SCHEMA_VERSION = 1
BUNDLE_IDENTIFIER = "com.vexsign.app"
MINIMUM_OS = "17.0"
BUILD_CHANNELS = {"development", "prerelease", "release"}
SIGNING_CLASSES = {"adHoc", "development", "enterprise", "appStore", "unsigned"}
DISTRIBUTION_METHODS = {
    "artifactDownload", "development", "adHoc", "enterprise", "appStore", "testFlight"
}
FORBIDDEN_MEMBER_RE = re.compile(
    r"(^|/)(?:\.git|\.svn|Tests?|Fixtures?)(/|$)|(?:\.pem|\.p12|\.cer|\.key|\.mobileprovision)$|^\.DS_Store$",
    re.IGNORECASE,
)
INFO_RE = re.compile(r"^Payload/[^/]+\.app/Info\.plist$")
BUNDLE_RE = re.compile(r"^Payload/.*\.(?:app|appex)/Info\.plist$")


def sha256_file(path: Path) -> str:
    if not path.is_file() or path.is_symlink():
        raise ValueError(f"Expected a regular file: {path}")
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def _os_tuple(value: object) -> tuple[int, ...]:
    if not isinstance(value, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", value):
        raise ValueError(f"Invalid MinimumOSVersion: {value!r}")
    parts = [int(part) for part in value.split(".")]
    return tuple(parts + [0] * (3 - len(parts)))


def inspect_ipa(ipa: Path, expected_commit: str | None = None) -> dict:
    """Validate structure and metadata from the bytes that will be published."""
    if not ipa.is_file() or ipa.is_symlink():
        raise ValueError(f"IPA must be a regular file: {ipa}")
    with zipfile.ZipFile(ipa) as archive:
        names = archive.namelist()
        if not names:
            raise ValueError("IPA archive is empty")
        if len(names) != len(set(names)):
            raise ValueError("IPA contains duplicate archive members")
        corrupt = archive.testzip()
        if corrupt is not None:
            raise ValueError(f"IPA member is corrupt: {corrupt}")
        suspicious = [name for name in names if FORBIDDEN_MEMBER_RE.search(name)]
        if suspicious:
            raise ValueError("IPA contains development-only or credential-like members: "
                             + ", ".join(sorted(suspicious)[:5]))
        infos = [name for name in names if BUNDLE_RE.fullmatch(name)]
        roots = [name for name in infos if INFO_RE.fullmatch(name)]
        if len(roots) != 1:
            raise ValueError("IPA must contain exactly one root application Info.plist")
        info = plistlib.loads(archive.read(roots[0]))
        nested = [plistlib.loads(archive.read(name)) for name in infos if name not in roots]

    bundle_id = info.get("CFBundleIdentifier")
    if bundle_id != BUNDLE_IDENTIFIER:
        raise ValueError(f"Unexpected root bundle identifier: {bundle_id!r}")
    version = info.get("CFBundleShortVersionString")
    if not isinstance(version, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*(?:-[0-9A-Za-z.]+)?", version):
        raise ValueError(f"Invalid CFBundleShortVersionString: {version!r}")
    parse_version(version)
    build = validate_numeric_build(info.get("CFBundleVersion"))
    minimum_os = info.get("MinimumOSVersion")
    if _os_tuple(minimum_os) < _os_tuple(MINIMUM_OS):
        raise ValueError(f"IPA supports iOS {minimum_os!r}, below the required {MINIMUM_OS}")
    commit = info.get("VexSignSourceCommit")
    if not isinstance(commit, str) or not re.fullmatch(r"[a-f0-9]{7,40}", commit):
        raise ValueError("IPA has no valid VexSignSourceCommit build metadata")
    if expected_commit and commit != expected_commit.lower():
        raise ValueError("IPA source commit does not match the requested revision")
    channel = info.get("VexSignBuildChannel", "unset")
    if channel not in BUILD_CHANNELS:
        raise ValueError(f"IPA has an unrecognised VexSignBuildChannel: {channel!r}")
    identifiers = {bundle_id}
    for child in nested:
        identifier = child.get("CFBundleIdentifier")
        if not isinstance(identifier, str) or not identifier.startswith(bundle_id + "."):
            raise ValueError(f"Nested bundle identifier outside app namespace: {identifier!r}")
        if identifier in identifiers:
            raise ValueError(f"Duplicate bundle identifier: {identifier}")
        identifiers.add(identifier)
        if child.get("CFBundleVersion") != build:
            raise ValueError("Nested bundle CFBundleVersion does not match the root app")

    return {
        "bundle_identifier": bundle_id,
        "marketing_version": version,
        "build_number": build,
        "minimum_os_version": minimum_os,
        "source_commit": commit,
        "build_channel": channel,
        "bundle_identifiers": sorted(identifiers),
    }


def build_manifest(
    ipa: Path,
    *,
    source_commit: str,
    tag: str = "",
    xcode_version: str,
    swift_version: str,
    configuration: str,
    channel: str,
    signing_class: str = "adHoc",
    distribution_method: str = "artifactDownload",
    built_at: str | None = None,
) -> dict:
    if not re.fullmatch(r"[a-f0-9]{40}", source_commit):
        raise ValueError("A full 40-character Git commit is required")
    if tag and not TAG_RE.fullmatch(tag):
        raise ValueError(f"Invalid release tag: {tag!r}")
    if configuration not in {"Debug", "Debug-distribution", "Release", "Release-distribution"}:
        raise ValueError(f"Unexpected build configuration: {configuration!r}")
    if channel not in BUILD_CHANNELS:
        raise ValueError(f"Unexpected release channel: {channel!r}")
    if signing_class not in SIGNING_CLASSES or distribution_method not in DISTRIBUTION_METHODS:
        raise ValueError("Invalid signing class or distribution method")
    for label, value in (("Xcode", xcode_version), ("Swift", swift_version)):
        if not value or any(character in value for character in "\r\n"):
            raise ValueError(f"{label} version must be a single non-empty line")
    timestamp = built_at or datetime.now(timezone.utc).replace(microsecond=0).isoformat()
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\+00:00|Z)", timestamp):
        raise ValueError("--built-at must be an ISO-8601 UTC timestamp")

    metadata = inspect_ipa(ipa, expected_commit=source_commit)
    if tag and parse_tag(tag).base != parse_version(metadata["marketing_version"]).base:
        raise ValueError("Release tag does not match the built marketing version")
    if channel == "development" and not configuration.startswith("Debug"):
        raise ValueError("Development channel must use a Debug configuration")
    if channel in {"prerelease", "release"} and not configuration.startswith("Release"):
        raise ValueError(f"{channel} channel must use a Release configuration")
    device_installable = signing_class in {"development", "enterprise", "appStore"}

    return {
        "schema_version": SCHEMA_VERSION,
        "product": "VexSign",
        "artifact": {
            "filename": ipa.name,
            "size_bytes": ipa.stat().st_size,
            "sha256": sha256_file(ipa),
            **metadata,
        },
        "build": {
            "configuration": configuration,
            "channel": channel,
            "timestamp_utc": timestamp,
            "source_commit": source_commit,
            "release_tag": tag,
            "xcode_version": xcode_version,
            "swift_version": swift_version,
        },
        "signing": {
            "class": signing_class,
            "distribution_method": distribution_method,
            "signature_verified": False,
            "provisioning_profile_verified": False,
            "device_installable": device_installable,
        },
        "verification_boundary": (
            "Offline structure, metadata and checksum checks only. No Apple signature, "
            "provisioning profile or device-install verification was performed by this manifest."
        ),
    }


def write_manifest(directory: Path, manifest: dict, extra_files: tuple[str, ...] = ()) -> Path:
    payload = json.dumps(manifest, indent=2, sort_keys=True) + "\n"
    path = directory / "ARTIFACT.json"
    path.write_text(payload, encoding="utf-8")
    names = [manifest["artifact"]["filename"], path.name, *sorted(extra_files)]
    if len(names) != len(set(names)):
        raise ValueError("Duplicate checksum entry")
    lines = []
    for name in names:
        target = directory / name
        if not target.is_file() or target.is_symlink():
            raise ValueError(f"Checksum input is not a regular file: {name}")
        lines.append(f"{sha256_file(target)}  {name}\n")
    (directory / "SHA256SUMS").write_text("".join(lines), encoding="utf-8")
    return path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ipa", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True, help="directory for ARTIFACT.json/SHA256SUMS")
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--tag", default="")
    parser.add_argument("--xcode-version", required=True)
    parser.add_argument("--swift-version", required=True)
    parser.add_argument("--configuration", required=True)
    parser.add_argument("--channel", required=True)
    parser.add_argument("--signing-class", default="adHoc")
    parser.add_argument("--distribution-method", default="artifactDownload")
    parser.add_argument("--built-at", default=None)
    parser.add_argument("--checksum-extra", action="append", default=[])
    args = parser.parse_args()
    manifest = build_manifest(
        args.ipa,
        source_commit=args.source_commit,
        tag=args.tag,
        xcode_version=args.xcode_version,
        swift_version=args.swift_version,
        configuration=args.configuration,
        channel=args.channel,
        signing_class=args.signing_class,
        distribution_method=args.distribution_method,
        built_at=args.built_at,
    )
    path = write_manifest(args.output, manifest, tuple(args.checksum_extra))
    print(f"Wrote {path} ({manifest['artifact']['sha256']})")


if __name__ == "__main__":
    main()
