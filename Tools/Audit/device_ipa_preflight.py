#!/usr/bin/env python3
"""Offline evidence checks for a development-signed VexSign device-test IPA.

A PAIRING FILE AND A SIGNING IDENTITY IN THE KEYCHAIN ARE NOT EVIDENCE THAT THE
IPA ON THE RUNNER IS THE RIGHT ARTIFACT. This module reads only the IPA's metadata
and embedded provisioning profile; it never extracts or executes application
content. It complements, and does not replace, `xcrun devicectl install`.
"""

from __future__ import annotations

import datetime as dt
import plistlib
import re
import zipfile
from pathlib import Path

BUNDLE_ID = "com.vexsign.app"
MAX_INFO_BYTES = 1024 * 1024
MAX_PROFILE_BYTES = 4 * 1024 * 1024
TEAM_RE = re.compile(r"\b([A-Z0-9]{10})\b")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")


class IPAEvidenceError(ValueError):
    """The archive cannot establish the facts needed for a device run."""


def _root_app_prefix(names: list[str]) -> str:
    roots = {
        name.split("/")[1]
        for name in names
        if len(name.split("/")) >= 3 and name.split("/")[0] == "Payload" and name.split("/")[1].endswith(".app")
    }
    if len(roots) != 1:
        raise IPAEvidenceError("Expected exactly one root .app in Payload")
    return f"Payload/{roots.pop()}/"


def _profile_dictionary(raw: bytes) -> dict:
    """Decode a plist embedded in a CMS-signed mobileprovision without security tools."""
    starts = [raw.find(marker) for marker in (b"<?xml", b"bplist00")]
    starts = [index for index in starts if index >= 0]
    if not starts:
        raise IPAEvidenceError("Embedded provisioning profile has no readable plist payload")
    for start in sorted(starts):
        payload = raw[start:]
        if payload.startswith(b"<?xml"):
            end = payload.find(b"</plist>")
            if end >= 0:
                payload = payload[: end + len(b"</plist>")]
        try:
            parsed = plistlib.loads(payload)
        except (plistlib.InvalidFileException, ValueError, TypeError):
            continue
        if isinstance(parsed, dict):
            return parsed
    raise IPAEvidenceError("Embedded provisioning profile plist could not be decoded")


def inspect_ipa(path: Path) -> dict:
    """Return only bounded, non-secret metadata from the IPA."""
    path = Path(path)
    if not path.is_file():
        raise IPAEvidenceError(f"IPA not found: {path.name}")
    try:
        with zipfile.ZipFile(path) as archive:
            names = archive.namelist()
            root = _root_app_prefix(names)
            info_name = root + "Info.plist"
            profile_name = root + "embedded.mobileprovision"
            signature_name = root + "_CodeSignature/CodeResources"
            missing = [name for name in (info_name, profile_name, signature_name) if name not in names]
            if missing:
                raise IPAEvidenceError("Missing " + ", ".join(sorted(missing)))
            info_member = archive.getinfo(info_name)
            profile_member = archive.getinfo(profile_name)
            if not 0 < info_member.file_size <= MAX_INFO_BYTES:
                raise IPAEvidenceError("Info.plist is missing or exceeds the inspection limit")
            if not 0 < profile_member.file_size <= MAX_PROFILE_BYTES:
                raise IPAEvidenceError("Provisioning profile is missing or exceeds the inspection limit")
            info = plistlib.loads(archive.read(info_name))
            profile = _profile_dictionary(archive.read(profile_name))
    except (zipfile.BadZipFile, OSError, plistlib.InvalidFileException) as error:
        raise IPAEvidenceError(f"IPA metadata is unreadable: {type(error).__name__}") from error
    if not isinstance(info, dict):
        raise IPAEvidenceError("Info.plist is not a dictionary")
    executable = info.get("CFBundleExecutable")
    if not isinstance(executable, str) or not executable or root + executable not in names:
        raise IPAEvidenceError("Root app executable named by Info.plist is missing")
    return {"info": info, "profile": profile, "root": root}


def identity_team(identity: str) -> str:
    match = TEAM_RE.search(identity or "")
    return match.group(1) if match else ""


def validate(evidence: dict, commit: str, udid: str, identity: str, now: dt.datetime | None = None) -> list[str]:
    """Return every reason this artifact must not be installed by the device runner."""
    errors: list[str] = []
    info = evidence["info"]
    profile = evidence["profile"]
    if info.get("CFBundleIdentifier") != BUNDLE_ID:
        errors.append(f"IPA bundle identifier is not {BUNDLE_ID}")
    observed_commit = str(info.get("VexSignSourceCommit", "")).lower()
    if not COMMIT_RE.fullmatch(observed_commit) or observed_commit != commit.lower():
        errors.append("IPA VexSignSourceCommit does not match the run commit")
    channel = info.get("VexSignBuildChannel")
    if channel not in ("development", "prerelease"):
        errors.append("Device-test IPA must be built with a development or prerelease channel")
    if info.get("DTPlatformName") != "iphoneos":
        errors.append("IPA was not built for an iOS device")

    devices = profile.get("ProvisionedDevices")
    if not isinstance(devices, list) or udid not in devices:
        errors.append("Embedded provisioning profile does not authorize the selected device UDID")
    team = identity_team(identity)
    if not team:
        errors.append("Signing identity must include a 10-character team identifier for comparison")
    profile_teams = profile.get("TeamIdentifier")
    if not isinstance(profile_teams, list) or team not in profile_teams:
        errors.append("Provisioning profile team does not match the configured signing identity")
    app_id = (profile.get("Entitlements") or {}).get("application-identifier", "")
    if not isinstance(app_id, str) or not app_id.endswith("." + BUNDLE_ID):
        errors.append("Provisioning profile application identifier does not match VexSign")
    expiry = profile.get("ExpirationDate")
    if not isinstance(expiry, dt.datetime):
        errors.append("Provisioning profile has no parseable expiration date")
    elif expiry.tzinfo is None:
        if expiry <= (now or dt.datetime.now()):
            errors.append("Embedded provisioning profile has expired")
    elif expiry <= (now or dt.datetime.now(dt.timezone.utc)):
        errors.append("Embedded provisioning profile has expired")
    return errors


def check(path: Path, commit: str, udid: str, identity: str) -> tuple[dict, list[str]]:
    """Inspect and validate, converting malformed archives into one clear error."""
    try:
        evidence = inspect_ipa(path)
    except IPAEvidenceError as error:
        return {}, [str(error)]
    return evidence, validate(evidence, commit, udid, identity)


def main() -> None:
    import argparse

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ipa", type=Path, required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--device", required=True)
    parser.add_argument("--identity", default="", help="Only the team id is compared; the value is never printed")
    args = parser.parse_args()
    evidence, errors = check(args.ipa, args.commit, args.device, args.identity)
    if errors:
        parser.exit(1, "\n".join(errors) + "\n")
    info = evidence["info"]
    print(f"IPA preflight OK: {info['CFBundleIdentifier']} "
          f"{info.get('CFBundleShortVersionString', '?')} ({info.get('CFBundleVersion', '?')})")


if __name__ == "__main__":
    main()
