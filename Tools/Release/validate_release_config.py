#!/usr/bin/env python3
"""Block release builds with inconsistent or unsafe Xcode configuration.

Checks the four configurations already present in VexSign.xcodeproj (Debug,
Debug-distribution, Release, Release-distribution), the entitlements they use,
and the build-channel injected into Info.plist. It does not create new schemes
or mutate the project; it makes the existing ones auditable in CI.
"""

from __future__ import annotations

import argparse
import plistlib
import re
import subprocess
from pathlib import Path

from release_version import parse_tag, parse_version

ROOT = Path(__file__).resolve().parents[2]
PROJECT = ROOT / "VexSign.xcodeproj/project.pbxproj"
APP_CONFIG_IDS = {
    "Debug": ("3379C1CE2DA869A3004372DA", "development"),
    "Debug-distribution": ("3379C23F2E1E53D700A51209", "prerelease"),
    "Release": ("3379C1CF2DA869A3004372DA", "release"),
    "Release-distribution": ("3379C2422E1E53E400A51209", "release"),
}
BUNDLE_ID = "com.vexsign.app"
PRIVATE_KEY_RE = re.compile(rb"-----BEGIN (?:RSA |EC |DSA |OPENSSH |PGP )?PRIVATE KEY-----")


def parse_build_configs(project: str) -> dict[str, str]:
    start = project.index("/* Begin XCBuildConfiguration section */")
    end = project.index("/* End XCBuildConfiguration section */")
    pattern = re.compile(r"^\t\t([A-F0-9]{24}) /\* (.*?) \*/ = \{\n(.*?)^\t\t\};", re.M | re.S)
    return {match.group(1): match.group(3) for match in pattern.finditer(project[start:end])}


def setting(block: str, key: str) -> str:
    match = re.search(rf"^\s*{re.escape(key)} = ([^;]+);", block, re.M)
    return match.group(1).strip().strip('"') if match else ""


def tracked_files() -> list[str]:
    result = subprocess.run(["git", "ls-files", "-z"], cwd=ROOT, capture_output=True, check=True)
    return [name for name in result.stdout.decode("utf-8").split("\0") if name]


def validate(tag: str = "", build_number: str = "", secret_scan: bool = True) -> dict:
    project = PROJECT.read_text(encoding="utf-8")
    blocks = parse_build_configs(project)
    if not blocks:
        raise ValueError("Could not parse Xcode build configurations")

    versions = {setting(block, "MARKETING_VERSION") for block in blocks.values()}
    versions.discard("")
    if len(versions) != 1:
        raise ValueError(f"Targets disagree on MARKETING_VERSION: {sorted(versions)}")
    marketing = versions.pop()
    parsed = parse_version(marketing)
    if parsed.prerelease:
        raise ValueError("MARKETING_VERSION must be a release version; use a tag suffix for prereleases")
    if tag and parse_tag(tag).base != parsed.base:
        raise ValueError(f"Release tag {tag} does not match project version {marketing}")

    checked = {}
    for name, (config_id, expected_channel) in APP_CONFIG_IDS.items():
        block = blocks.get(config_id, "")
        if not block:
            raise ValueError(f"VexSign target configuration {name} is missing")
        if setting(block, "PRODUCT_BUNDLE_IDENTIFIER") != BUNDLE_ID:
            raise ValueError(f"{name} has the wrong bundle identifier")
        if setting(block, "DEVELOPMENT_TEAM") == "":
            raise ValueError(f"{name} has no development team")
        if setting(block, "CODE_SIGN_STYLE") != "Manual":
            raise ValueError(f"{name} must use explicit Manual signing")
        if setting(block, "IPHONEOS_DEPLOYMENT_TARGET") != "17.0":
            raise ValueError(f"{name} deployment target is not iOS 17.0")
        if setting(block, "VEXSIGN_BUILD_CHANNEL") != expected_channel:
            raise ValueError(f"{name} build channel is not {expected_channel}")
        entitlements = setting(block, "CODE_SIGN_ENTITLEMENTS")
        if not entitlements or not (ROOT / entitlements).is_file():
            raise ValueError(f"{name} references a missing entitlements file")
        if name.startswith("Release"):
            conditions = setting(block, "SWIFT_ACTIVE_COMPILATION_CONDITIONS").upper()
            if "DEBUG" in conditions:
                raise ValueError(f"{name} must not define DEBUG")
            if setting(block, "SWIFT_OPTIMIZATION_LEVEL") not in {"-O", "-Osize"}:
                raise ValueError(f"{name} needs an explicit optimized Swift setting")
            if setting(block, "DEBUG_INFORMATION_FORMAT") != "dwarf-with-dsym":
                raise ValueError(f"{name} needs dSYM debug information")
        else:
            if "DEBUG" not in setting(block, "SWIFT_ACTIVE_COMPILATION_CONDITIONS").upper():
                raise ValueError(f"{name} should define DEBUG")
        current = setting(block, "CURRENT_PROJECT_VERSION")
        if not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", current):
            raise ValueError(f"{name} has an invalid CFBundleVersion: {current!r}")
        if build_number and current != build_number:
            raise ValueError(f"{name} build number {current} differs from {build_number}")
        checked[name] = {"channel": expected_channel, "bundle_identifier": BUNDLE_ID, "build": current}

    entitlements_path = ROOT / "Config/Entitlements/iOS/VexSign.entitlements"
    entitlements = plistlib.loads(entitlements_path.read_bytes())
    if entitlements.get("get-task-allow") is not False:
        raise ValueError("iOS entitlements must explicitly disable get-task-allow")
    groups = entitlements.get("com.apple.security.application-groups", [])
    if groups != ["group.com.vexsign.app"]:
        raise ValueError("iOS app group differs from the configured VexSign group")

    info = (ROOT / "Config/BuildSettings/iOS/Info.plist").read_text(encoding="utf-8")
    if "<key>VexSignBuildChannel</key>" not in info or "$(VEXSIGN_BUILD_CHANNEL)" not in info:
        raise ValueError("Info.plist does not consume the injected build channel")

    if secret_scan:
        suspicious_extensions = {".pem", ".p12", ".pfx", ".p8", ".key", ".cer", ".mobileprovision"}
        for name in tracked_files():
            lowered = name.lower()
            # Synthetic key text in a documented test fixture is not a credential.
            if any(part in lowered for part in ("test", "fixture", "sample", "docs")):
                continue
            path = ROOT / name
            if not path.is_file() or path.stat().st_size > 2_000_000:
                continue
            if path.suffix.lower() in suspicious_extensions or PRIVATE_KEY_RE.search(path.read_bytes()):
                raise ValueError(f"Private key material is committed: {name}")

    return {
        "ok": True,
        "marketing_version": marketing,
        "tag": tag,
        "configurations": checked,
        "secret_scan": "performed" if secret_scan else "skipped",
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", default="")
    parser.add_argument("--build-number", default="")
    parser.add_argument("--skip-secret-scan", action="store_true")
    args = parser.parse_args()
    try:
        report = validate(args.tag, args.build_number, secret_scan=not args.skip_secret_scan)
    except (ValueError, OSError, plistlib.InvalidFileException, subprocess.CalledProcessError) as error:
        parser.exit(1, f"release configuration invalid: {error}\n")
    import json
    print(json.dumps(report, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
