#!/usr/bin/env python3
"""Single source for VexSign's honest real-device capability matrix.

Every row is tied to code that exists in this repository. The verification
column is deliberately conservative: a source file, a unit test or a simulator
run is not a physical-device pass. Regenerate the checked-in document with
``--write`` and enforce it with ``--check``.
"""

from __future__ import annotations

import argparse
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DOCUMENT = ROOT / "Docs/DeviceTesting/device-capability-matrix.md"

BASE = "iOS 17.0"
PAIRED = "iOS 17.4+ (classic); iOS 26.4+ remote record; iOS 27+ on-device host"
LOCAL = "Implemented but not tested"
HARDWARE = "Blocked by external prerequisite"
CI_STATIC = "Implemented but not tested (local static gate)"

# id, name, iOS, device state, permissions, credentials, profile, network, companion,
# success, failure, verification, evidence
CAPABILITIES = [
    ("app_lifecycle", "Application launch, relaunch and lifecycle", BASE,
     "Installed VexSign; unlocked after first launch", "Notifications only if enabled; Face ID only if App Lock is on",
     "None for launch", "Distribution/development profile used to install VexSign", "Not required",
     "None", "Identity, version and tab bar are present after launch and relaunch",
     "Launch fails; no workflow is marked complete", LOCAL,
     "VexSign/App/VexSignApp.swift; VexSign/App/AppDelegate.swift"),
    ("ipa_import", "IPA file selection and import", BASE,
     "Files access to the chosen archive", "Files/document picker granted by the user",
     "None", "None", "Not required", "None",
     "One library row with extracted metadata; temporary work removed",
     "Malformed archive rejected; no partial library row; no completed task", LOCAL,
     "VexSign/Services/Import/IPA/PackageImportService.swift; VexSign/Security/ArchiveValidation/ArchiveSafetyValidator.swift"),
    ("archive_inspection", "Archive inspection and metadata extraction", BASE,
     "Imported or staged archive", "None", "None", "None", "Not required", "None",
     "Bundle id, version and executable are read from exactly one root app",
     "Ambiguous, oversized or unsafe members are rejected", CI_STATIC,
     "VexSign/Services/Import/Inspection/IPAArchiveInspector.swift"),
    ("certificate_management", "Certificate import, validation and Keychain persistence", BASE,
     "Device unlocked for Keychain access", "File access to PKCS#12/profile; import consent",
     "Certificate password when protected", "Imported signing identity; private key held by Keychain",
     "Not required", "None", "Identity appears with pairing/expiry state; survives relaunch",
     "Wrong password or unreadable key leaves prior identities intact", HARDWARE,
     "VexSign/Services/CertificateVault; VexSign/Services/Identity/CertificateManagementService.swift"),
    ("profile_parsing", "Provisioning-profile parsing", BASE,
     "Profile file available", "None", "None", "Profile under test", "Not required", "None",
     "Bundle id, team, devices, entitlements and expiry are reported",
     "Malformed/expired/incorrect profile is refused", CI_STATIC,
     "Packages/NativeSigning/Provisioning/NativeProvisioningProfileValidator.swift"),
    ("signing", "Signing with a compatible identity", BASE,
     "Imported app and usable identity", "None", "Identity password/Keychain unlock when needed",
     "Non-revoked, unexpired identity and compatible profile", "Not required", "None",
     "One signed artifact registered; task reaches signed/completed",
     "Incompatible identity/profile stops before a usable artifact exists", HARDWARE,
     "VexSign/Services/Signing/Execution/PackageSigningCoordinator.swift"),
    ("signature_verification", "Signature and entitlement verification", BASE,
     "Signed bundle available", "None", "None", "Signer identity evidence", "Not required", "None",
     "verdict.isVerified and requireVerified() pass before registration",
     "Invalid or incomplete evidence blocks success", CI_STATIC,
     "VexSign/Services/Signing/Verification/SignerMatch.swift"),
    ("device_discovery", "Device discovery", PAIRED,
     "Compatible pairing record and unlocked device", "Explicit experimental device-service consent",
     "None", "Pairing record with matching device identity", "Local pairing transport", "Companion service for classic/remote records",
     "Fresh device query reports the selected device",
     "No connected state without a fresh authorized answer", HARDWARE,
     "VexSign/Services/Devices/DeviceRegistryService.swift"),
    ("device_pairing", "Pairing state and trust", PAIRED,
     "Trust prompt accepted on device", "Device unlocked; Trust tapped",
     "None", "Valid classic/remote record or iOS 27+ on-device host", "Local transport", "Host for iOS 27+ bootstrap",
     "Pairing state is validated and bound to one device identity",
     "Unauthorized/revoked pairing is not silently reused", HARDWARE,
     "VexSign/Services/Installation/Transport/PairingBridge.swift"),
    ("device_connection", "Connection establishment, interruption and recovery", PAIRED,
     "Fresh session available", "Explicit consent", "None", "Compatible pairing record", "Local transport", "Companion where required",
     "Presence becomes connected only after a session succeeds",
     "Timeout/disconnect returns to reconnecting/unavailable; no stale connected badge", HARDWARE,
     "VexSign/Services/Installation/Transport/DeviceConnectivity.swift"),
    ("installation", "Paired application installation", PAIRED,
     "Verified signed artifact and connected trusted device", "Trust/Developer Mode where iOS requires it",
     "None", "Device-authorizing profile for the target app", "Local pairing transport", "Companion where required",
     "Device inventory confirms the exact version; app launches",
     "No installed-state record on failure or unconfirmed result", HARDWARE,
     "VexSign/Services/Installation/Installation/AppInstaller.swift"),
    ("install_status", "Installation status evidence", PAIRED,
     "Recent installation attempt", "None", "None", "None", "Local transport", "Companion where required",
     "Installed evidence comes from a device query, not a command acknowledgement",
     "Unknown/placeholder state stays unconfirmed", CI_STATIC,
     "VexSign/Services/Installation/Installation/InstalledAppProbe.swift"),
    ("inventory", "Installed-application inventory", PAIRED,
     "Accepted same-device inventory bridge", "Explicit consent", "None", "Compatible pairing record", "Local transport", "Companion where required",
     "Bundle list with comparable version metadata",
     "Missing/unreadable inventory is reported as unavailable, not empty success", HARDWARE,
     "VexSign/Services/Installation/Transport/DeviceInstalledAppInventory.swift"),
    ("updates", "Application update detection and download hand-off", BASE,
     "Configured source and installed app", "None", "Optional premium key", "Usable signing identity for a later install",
     "HTTPS source access", "None",
     "Update detected and download registered with an integrity expectation",
     "Refused download is reported as refused; stale offline snapshot retained on refresh failure", CI_STATIC,
     "VexSign/Services/Catalog/CatalogUpdateDetector.swift"),
    ("backup_restore", "Backup and restore", BASE,
     "Encrypted archive or preview available", "File access; destructive-confirmation consent",
     "Backup password", "None", "Not required", "None",
     "Conflict preview then explicit restore; prior records preserved",
     "Cancelled/invalid archive never replaces a valid backup", HARDWARE,
     "VexSign/Features/Backup; VexSign/Services/Backup"),
    ("containers", "VexSign-owned container archives", BASE,
     "VexSign container manifest available", "Explicit replace/create authorization", "None", "None", "Not required", "None",
     "VexSign-owned container restored with an explicit target",
     "Third-party app sandbox is never claimed or modified", HARDWARE,
     "VexSign/Services/Containers"),
    ("notifications_background", "Notifications and background execution", BASE,
     "Notification permission granted; app backgrounded", "User notification authorization",
     "None", "None", "Delivery may require network", "None",
     "Notification routes to a screen; operation reconciles on foreground",
     "iOS may suspend work; expiration is reported, not hidden", HARDWARE,
     "VexSign/App/AppDelegate+BackgroundTasks.swift; VexSign/Services/Notifications"),
    ("diagnostics", "Diagnostics and sanitized export", BASE,
     "Controlled failure reproduced", "None", "None", "None", "Not required", "None",
     "Structured event with operation id, category, error code, duration and recovery",
     "No credential, private key or UDID in the exported event", CI_STATIC,
     "VexSign/Services/Diagnostics/DiagnosticEvent.swift"),
    ("network", "Repository, download and local-network operations", BASE,
     "Source/server configured", "Local Network permission for LAN features", "Optional premium key", "None",
     "HTTPS remote or opted-in LAN HTTP", "Local server/companion for LAN routes",
     "Bounded response, validated URL and integrity expectation",
     "Redirect downgrade, oversized or malformed response is refused", CI_STATIC,
     "VexSign/Security/Policies/PackageDownloadURLPolicy.swift"),
    ("computer_free_bootstrap", "Computer-free VexSign installation (iOS 27+)", "iOS 27+",
     "On-device RPPairing host available", "Device PIN confirmation and install confirmation",
     "Apple Account sign-in when required", "Valid provisioning profile for VexSign", "Local host discovery",
     "No companion computer for this route",
     "IPA installed, launched and matched to the report checksum",
     "Unsupported on earlier iOS; cancel/network failure leaves no false pass", HARDWARE,
     "Docs/DeviceTesting/bootstrap.md; Tools/Audit/device-acceptance.py"),
]


def render_markdown() -> str:
    lines = [
        "# VexSign real-device capability matrix",
        "",
        "Generated from `Tools/Audit/device_capability_matrix.py`. Do not edit by hand;",
        "run `python3 Tools/Audit/device_capability_matrix.py --write`.",
        "",
        "Labels are evidence statements, not aspirations. `Implemented but not tested` means",
        "code exists and local static gates pass; `Blocked by external prerequisite` means a",
        "device, Apple credential, profile, pairing record or companion service is required.",
        "No row claims a physical-device pass in this repository.",
        "",
        "| Capability | Minimum iOS | Device state / permissions | Credentials / profile | Network / companion | Expected success | Expected failure | Verification | Evidence |",
        "| --- | --- | --- | --- | --- | --- | --- | --- | --- |",
    ]
    for (identifier, name, ios, state, permissions, credentials, profile, network, companion,
         success, failure, verification, evidence) in CAPABILITIES:
        requirements = f"{state}; {permissions}".replace("|", "\\|")
        security = f"{credentials}; {profile}".replace("|", "\\|")
        transport = f"{network}; {companion}".replace("|", "\\|")
        lines.append(
            f"| {name} | {ios} | {requirements} | {security} | {transport} | "
            f"{success} | {failure} | {verification} | `{evidence}` |"
        )
    lines += [
        "",
        "## Installation model boundary",
        "",
        "VexSign itself is installed by a development-signed IPA (computer-assisted), an",
        "ad hoc artifact that must be re-signed, TestFlight/App Store distribution, or — only",
        "on iOS 27+ with an available on-device RPPairing host — the opt-in computer-free",
        "bootstrap. The last route is an acceptance path, not a claim that it has passed.",
        "VexSign's *own* installation of other apps uses the verified signing output over a",
        "paired session, the local HTTPS server, or an eligible external installer. A",
        "simulator cannot authorize any of those device installation routes.",
        "",
    ]
    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--write", action="store_true", help="Regenerate the checked-in document")
    group.add_argument("--check", action="store_true", help="Fail when the document is stale")
    args = parser.parse_args()
    rendered = render_markdown()
    if args.write:
        DOCUMENT.write_text(rendered, encoding="utf-8")
        print(f"wrote {DOCUMENT.relative_to(ROOT)} ({len(CAPABILITIES)} capabilities)")
        return
    if not DOCUMENT.is_file() or DOCUMENT.read_text(encoding="utf-8") != rendered:
        raise SystemExit("device capability matrix is stale; run device_capability_matrix.py --write")
    forbidden = ("Verified on physical hardware", "Verified in CI", "Verified in simulator")
    for token in forbidden:
        if token in rendered:
            raise SystemExit(f"matrix must not claim {token!r} without run evidence")
    print(f"device capability matrix OK ({len(CAPABILITIES)} capabilities)")


if __name__ == "__main__":
    main()
