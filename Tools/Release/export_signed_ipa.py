#!/usr/bin/env python3
"""Opt-in export of a signed IPA from an existing Xcode archive.

This script is intentionally *not* part of the hosted release job. It exists for
a configured Mac with real Apple distribution material supplied through the
environment. It never embeds credentials, never enables automatic signing, and
never claims TestFlight/App Store acceptance or device installation. Use
verify_artifact.py afterwards with the generated manifest for full validation.
"""

from __future__ import annotations

import argparse
import os
import plistlib
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

from verify_artifact import verify_signing

TEAM_RE = re.compile(r"^[A-Z0-9]{10}$")
METHODS = {"development": "development", "adHoc": "adHoc", "appStore": "appStore"}


def resolve_signing_inputs(environment: dict[str, str] | None = None) -> dict[str, str]:
    env = environment if environment is not None else os.environ
    values = {
        "team_id": env.get("VEXSIGN_RELEASE_TEAM_ID", ""),
        "identity": env.get("VEXSIGN_RELEASE_SIGNING_IDENTITY", ""),
        "profile": env.get("VEXSIGN_RELEASE_PROVISIONING_PROFILE", ""),
    }
    if not all(values.values()):
        raise ValueError(
            "VEXSIGN_RELEASE_TEAM_ID, VEXSIGN_RELEASE_SIGNING_IDENTITY and "
            "VEXSIGN_RELEASE_PROVISIONING_PROFILE must all be set"
        )
    if not TEAM_RE.fullmatch(values["team_id"]):
        raise ValueError("VEXSIGN_RELEASE_TEAM_ID must be a 10-character Apple TEAMID")
    for key in ("identity", "profile"):
        if any(char in values[key] for char in "\r\n") or len(values[key]) > 200:
            raise ValueError(f"{key} contains an invalid character or is too long")
    return values


def export_options(method: str, signing: dict[str, str]) -> dict:
    options = {
        "method": method,
        "teamID": signing["team_id"],
        "signingStyle": "manual",
        "signingIdentity": signing["identity"],
        "provisioningProfiles": {"com.vexsign.app": signing["profile"]},
        "compileBitcode": False,
    }
    if method == "appStore":
        options["destination"] = "upload"
    return options


def export_signed_archive(archive: Path, export_dir: Path, method: str,
                          signing: dict[str, str], *, dry_run: bool = False) -> dict:
    """Validate inputs, then call xcodebuild -exportArchive with explicit signing."""
    if method not in METHODS:
        raise ValueError(f"Unsupported distribution method: {method!r}")
    resolved = resolve_signing_inputs(signing)
    if not archive.is_dir() or not (archive / "Products/Applications/VexSign.app").is_dir():
        raise ValueError("Archive does not contain Products/Applications/VexSign.app")
    options = export_options(METHODS[method], resolved)
    # Names are shown, never certificate material or account credentials.
    plan = {
        "archive": str(archive),
        "export_directory": str(export_dir),
        "method": method,
        "team_id": resolved["team_id"],
        "identity": "<from environment>",
        "profile": "<from environment>",
        "command": "xcodebuild -exportArchive (manual signing, no provisioning updates)",
    }
    if dry_run:
        return plan
    if not (shutil.which("xcodebuild") and shutil.which("codesign") and shutil.which("security")):
        raise ValueError("Signed export requires xcodebuild, codesign and security on macOS")
    export_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="vexsign-export-") as directory:
        plist_path = Path(directory) / "ExportOptions.plist"
        plist_path.write_bytes(plistlib.dumps(options))
        environment = {**os.environ, "CODE_SIGNING_REQUIRED": "YES"}
        result = subprocess.run(
            ["xcodebuild", "-exportArchive", "-archivePath", str(archive),
             "-exportPath", str(export_dir), "-exportOptionsPlist", str(plist_path)],
            capture_output=True, text=True, check=False, env=environment,
        )
        if result.returncode != 0:
            raise ValueError("xcodebuild -exportArchive failed: "
                             + (result.stderr or result.stdout).strip()[-800:])
    ipas = sorted(export_dir.glob("*.ipa"))
    if len(ipas) != 1:
        raise ValueError("Export must produce exactly one IPA")
    signing_class = {"development": "development", "adHoc": "adHoc", "appStore": "appStore"}[method]
    signature = verify_signing(
        ipas[0],
        {"signing": {"class": signing_class}},
        require_signature=True,
    )
    return {
        **plan,
        "ipa": ipas[0].name,
        "signature": signature["signature"],
        "installation_verified": False,
        "boundary": (
            "Signature and profile were checked with Apple tools. Device installation, "
            "UDID membership and App Store Connect acceptance were not performed."
        ),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--export-directory", type=Path, required=True)
    parser.add_argument("--method", choices=sorted(METHODS), required=True)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    try:
        signing = resolve_signing_inputs()
        report = export_signed_archive(args.archive, args.export_directory, args.method,
                                       signing, dry_run=args.dry_run)
    except (ValueError, OSError) as error:
        parser.exit(1, f"signed export failed: {error}\n")
    import json
    print(json.dumps(report, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
