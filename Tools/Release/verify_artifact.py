#!/usr/bin/env python3
"""Independently verify a release IPA against its manifest.

Offline mode validates structure, metadata, checksum and manifest consistency.
It deliberately refuses to call an ad-hoc signed artifact installable. Pass
--require-signature on a macOS host with codesign/security to validate Apple
signing and the embedded provisioning profile; failures stop the process.
"""

from __future__ import annotations

import argparse
import json
import plistlib
import re
import shutil
import subprocess
import tempfile
import zipfile
from pathlib import Path

from artifact_manifest import (
    BUNDLE_IDENTIFIER,
    SCHEMA_VERSION,
    inspect_ipa,
    sha256_file,
)

SECRET_KEY_RE = re.compile(r"(password|passwd|secret|token|privatekey|apikey|credential)", re.IGNORECASE)


def load_manifest(path: Path) -> dict:
    if not path.is_file() or path.is_symlink():
        raise ValueError(f"Manifest is not a regular file: {path}")
    try:
        manifest = json.loads(path.read_text(encoding="utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError("Manifest is not valid UTF-8 JSON") from error
    if not isinstance(manifest, dict) or manifest.get("schema_version") != SCHEMA_VERSION:
        raise ValueError("Unsupported manifest schema")
    def secret_keys(value: object) -> set[str]:
        found: set[str] = set()
        if isinstance(value, dict):
            for key, child in value.items():
                if SECRET_KEY_RE.search(str(key)):
                    found.add(str(key))
                found.update(secret_keys(child))
        elif isinstance(value, list):
            for child in value:
                found.update(secret_keys(child))
        return found

    leaked = sorted(secret_keys(manifest))
    if leaked:
        raise ValueError(f"Manifest contains secret-like keys: {leaked}")
    for section in ("artifact", "build", "signing"):
        if not isinstance(manifest.get(section), dict):
            raise ValueError(f"Manifest is missing the {section} object")
    return manifest


def verify_offline(ipa: Path, manifest: dict, *, expected_commit: str = "",
                   expected_tag: str = "", expected_version: str = "") -> dict:
    artifact = manifest["artifact"]
    build = manifest["build"]
    if artifact.get("filename") != ipa.name:
        raise ValueError("IPA filename does not match the manifest")
    if not ipa.is_file() or ipa.is_symlink():
        raise ValueError("IPA is missing or is not a regular file")
    actual_digest = sha256_file(ipa)
    if actual_digest != artifact.get("sha256"):
        raise ValueError("IPA SHA-256 does not match the manifest")
    actual_size = ipa.stat().st_size
    if actual_size != artifact.get("size_bytes"):
        raise ValueError("IPA size does not match the manifest")
    metadata = inspect_ipa(ipa)
    for key in ("bundle_identifier", "marketing_version", "build_number",
                "minimum_os_version", "source_commit", "build_channel"):
        if metadata[key] != artifact.get(key):
            raise ValueError(f"IPA {key} does not match the manifest")
    if metadata["bundle_identifiers"] != artifact.get("bundle_identifiers"):
        raise ValueError("IPA bundle list does not match the manifest")
    if metadata["bundle_identifier"] != BUNDLE_IDENTIFIER:
        raise ValueError("Unexpected application bundle identifier")
    if expected_commit and metadata["source_commit"] != expected_commit.lower():
        raise ValueError("IPA was built from a different commit")
    if expected_tag and build.get("release_tag") != expected_tag:
        raise ValueError("Manifest release tag does not match the requested tag")
    if expected_version and metadata["marketing_version"] != expected_version:
        raise ValueError("Built marketing version does not match the requested version")
    for required in ("xcode_version", "swift_version", "configuration", "channel"):
        if not isinstance(build.get(required), str) or not build[required].strip():
            raise ValueError(f"Manifest build metadata {required} is missing")
    if not re.fullmatch(r"[a-f0-9]{40}", str(build.get("source_commit", ""))):
        raise ValueError("Manifest source commit is not a full SHA")
    return {"metadata": metadata, "sha256": actual_digest}


def _find_app(ipa: Path, temp: Path) -> Path:
    with zipfile.ZipFile(ipa) as archive:
        names = archive.namelist()
        roots = [name for name in names if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", name)]
        if len(roots) != 1:
            raise ValueError("Signature check needs exactly one root .app bundle")
        for name in names:
            if name.startswith("/") or ".." in Path(name).parts:
                raise ValueError("Unsafe archive member path")
        archive.extractall(temp)
    apps = sorted((temp / "Payload").glob("*.app"))
    if len(apps) != 1:
        raise ValueError("Signature check could not locate the extracted app")
    return apps[0]


def verify_signing(ipa: Path, manifest: dict, *, require_signature: bool = True) -> dict:
    """Use Apple's tools when available; otherwise report the exact boundary."""
    codesign = shutil.which("codesign")
    security = shutil.which("security")
    if not require_signature:
        return {"signature": "not requested", "provisioning_profile": "not requested"}
    if not codesign or not security:
        raise ValueError(
            "Signature verification requires codesign and security on macOS; "
            "the offline artifact remains unverified for installation"
        )
    with tempfile.TemporaryDirectory(prefix="vexsign-verify-") as directory:
        app = _find_app(ipa, Path(directory))
        result = subprocess.run(
            [codesign, "--verify", "--deep", "--strict", "--verbose=2", str(app)],
            capture_output=True, text=True, check=False,
        )
        if result.returncode != 0:
            raise ValueError("codesign rejected the app: " + (result.stderr or result.stdout).strip()[:500])
        profile = app / "embedded.mobileprovision"
        if not profile.is_file():
            raise ValueError("A device-installable release requires an embedded provisioning profile")
        decoded = subprocess.run(
            [security, "cms", "-D", "-i", str(profile)],
            capture_output=True, check=False,
        )
        if decoded.returncode != 0:
            raise ValueError("security could not decode the embedded provisioning profile")
        try:
            payload = plistlib.loads(decoded.stdout)
        except plistlib.InvalidFileException as error:
            raise ValueError("Embedded provisioning profile is not a valid plist") from error
        app_id = payload.get("application-identifier", "")
        if not isinstance(app_id, str) or not app_id.endswith("." + BUNDLE_IDENTIFIER):
            raise ValueError("Provisioning profile does not authorise the VexSign bundle identifier")
        entitlements = payload.get("Entitlements") or {}
        if entitlements.get("get-task-allow") is True:
            raise ValueError("Distribution profile enables get-task-allow (development signing)")
        team_id = app_id.split(".", 1)[0]
        signing = manifest["signing"]
        if signing.get("class") not in {"development", "adHoc", "enterprise", "appStore"}:
            raise ValueError("Manifest signing class is not device-installable")
        return {
            "signature": "codesign --verify --deep --strict passed",
            "provisioning_profile": f"decoded; team={team_id}; application-identifier={app_id}",
            "team_identifier": team_id,
        }


def verify(ipa: Path, manifest_path: Path, *, expected_commit: str = "", expected_tag: str = "",
           expected_version: str = "", require_signature: bool = False,
           require_installable: bool = False) -> dict:
    manifest = load_manifest(manifest_path)
    offline = verify_offline(ipa, manifest, expected_commit=expected_commit,
                             expected_tag=expected_tag, expected_version=expected_version)
    signed = verify_signing(ipa, manifest, require_signature=require_signature)
    if require_installable:
        if not require_signature:
            raise ValueError("--require-installable also requires --require-signature")
        if signed.get("signature") == "not requested":
            raise ValueError("Installability could not be established")
    signing = manifest["signing"]
    device_installable = bool(signing.get("device_installable")) and require_signature
    return {
        "ok": True,
        "sha256": offline["sha256"],
        "bundle_identifier": offline["metadata"]["bundle_identifier"],
        "version": offline["metadata"]["marketing_version"],
        "build": offline["metadata"]["build_number"],
        "source_commit": offline["metadata"]["source_commit"],
        "signature": signed["signature"],
        "provisioning_profile": signed["provisioning_profile"],
        "device_installable": device_installable,
        "boundary": manifest.get("verification_boundary", ""),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ipa", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--expected-commit", default="")
    parser.add_argument("--expected-tag", default="")
    parser.add_argument("--expected-version", default="")
    parser.add_argument("--require-signature", action="store_true")
    parser.add_argument("--require-installable", action="store_true")
    args = parser.parse_args()
    try:
        report = verify(
            args.ipa, args.manifest, expected_commit=args.expected_commit,
            expected_tag=args.expected_tag, expected_version=args.expected_version,
            require_signature=args.require_signature,
            require_installable=args.require_installable,
        )
    except (ValueError, OSError, zipfile.BadZipFile) as error:
        parser.exit(1, f"release verification failed: {error}\n")
    print(json.dumps(report, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
