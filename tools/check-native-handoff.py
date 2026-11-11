#!/usr/bin/env python3
"""Keeps the native-signing capability claim tied to the wiring that backs it.

`SigningMethodCapabilities.nativeAppleAccountSigning` is a claim about the app,
not a preference. When the Free Apple ID handoff landed as "recorded profile,
nothing signed", the flag and the UI copy were correct — the risk is that one of
them moves on its own:

  * the flag is flipped to `.implemented` while no adapter converts a native
    identity into the certificate store the signer reads;
  * the "not enabled in this build" copy is deleted as if the seam existed;
  * a package-side profile export appears (the missing piece) but the doc and
    the flag still describe the old state, so nothing gets re-reviewed.

This check encodes the current, deliberate state. It is meant to be updated in
the same change that implements the seam — see docs/NATIVE_SIGNING_HANDOFF.md.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CAPABILITIES = ROOT / "VexSign" / "Backend" / "Services" / "SigningMethodCapabilities.swift"
MANAGER = ROOT / "VexSign" / "Backend" / "Services" / "NativeSigningManager.swift"
FLOW = ROOT / "VexSign" / "Views" / "Settings" / "ProvisioningFlowView.swift"
BACKEND = ROOT / "NativeSigning" / "Authentication" / "NativeAccountBackend.swift"
HANDOFF_DOC = ROOT / "docs" / "NATIVE_SIGNING_HANDOFF.md"

problems: list[str] = []


def read(path: Path) -> str:
    if not path.is_file():
        problems.append(f"missing file: {path.relative_to(ROOT)}")
        return ""
    return path.read_text()


capabilities = read(CAPABILITIES)
manager = read(MANAGER)
flow = read(FLOW)
backend = read(BACKEND)
doc = read(HANDOFF_DOC)

# 1. The claim itself.
claim = re.search(r"nativeAppleAccountSigning:\s*\.(\w+)", capabilities)
if not claim:
    problems.append("SigningMethodCapabilities: nativeAppleAccountSigning assignment not found")
    native_integrated = False
else:
    native_integrated = claim.group(1) == "implemented"

# 2. An app-side adapter must exist before anything claims integration.
#
# A real adapter hands PKCS#12 bytes and profile bytes to the certificate store.
# Until one exists, `.implemented` would be a claim with no consumer.
def app_exports_native_identity() -> bool:
    return bool(re.search(r"func\s+\w*[eE]xport\w*\([^)]*NativeKeyExportConsent", manager))

has_app_adapter = app_exports_native_identity()

# 3. A package-side profile export is the other prerequisite: without profile
#    bytes the signer has nothing to sign against.
def package_exports_profile() -> bool:
    public_functions = re.findall(r"public func (\w+)\(", backend)
    return any("rofile" in name and "xport" in name for name in public_functions)


has_profile_export = package_exports_profile()

if native_integrated and not has_app_adapter:
    problems.append(
        "nativeAppleAccountSigning is .implemented but NativeSigningManager has no "
        "export-to-certificate-store adapter (no func taking NativeKeyExportConsent)"
    )

if native_integrated and not has_profile_export:
    problems.append(
        "nativeAppleAccountSigning is .implemented but NativeAccountBackend exposes no "
        "public profile export; the signer cannot receive a provisioning profile"
    )

# 4. The UI must not claim the seam exists unless it does, and must not keep
#    telling the user it is missing once it is wired.
says_not_enabled = "Native signing handoff is not enabled" in flow
if native_integrated and says_not_enabled:
    problems.append(
        "ProvisioningFlowView still says native signing handoff is not enabled while "
        "the capability claims .implemented"
    )
if not native_integrated and not says_not_enabled:
    problems.append(
        "ProvisioningFlowView no longer explains that native handoff is missing, but the "
        "capability is still .notIntegrated; update both in the same change"
    )

# 5. Nothing may claim that renewal happens. The identity split is only honest if
#    the free-Apple-ID side stops at "here is what is expiring".
#
#    `NativeSigningManager` used to expose `renewExpiringProfiles()` and
#    `BackgroundAutomation` a `renewFreeAppleIDProfiles()` step. Both only refreshed
#    a candidate list. The names are the hazard: a maintainer reads a scheduled
#    "renew" step, assumes renewal ships, and later reports it as working.
RENEWAL_CLAIMS = {
    "VexSign/Backend/Services/NativeSigningManager.swift": MANAGER,
    "VexSign/Backend/Observable/BackgroundAutomation.swift":
        ROOT / "VexSign" / "Backend" / "Observable" / "BackgroundAutomation.swift",
    "VexSign/Backend/Services/SigningMethod.swift":
        ROOT / "VexSign" / "Backend" / "Services" / "SigningMethod.swift",
}
#    Only real code counts. The explanations of *why* the claims were removed name the
#    old spellings on purpose, so full-line comments are stripped before matching.
def code_only(text: str) -> str:
    return "\n".join(
        line for line in text.splitlines() if not line.lstrip().startswith(("//", "///"))
    )


for label, path in RENEWAL_CLAIMS.items():
    text = read(path)
    if not text:
        continue
    body = code_only(text)
    for bad in ("func renewExpiringProfiles", "func renewFreeAppleIDProfiles"):
        if bad in body:
            problems.append(
                f"{label}: `{bad}` is back; it only refreshes a candidate list, so the "
                "name overstates what runs. Keep the refresh verb."
            )
    if "supportsAutoRefresh" in body:
        problems.append(
            f"{label}: `supportsAutoRefresh` is back; nothing in this build refreshes a "
            "free-Apple-ID profile automatically, so the property is an unbacked claim."
        )
    if "Weekly refresh" in body:
        problems.append(
            f"{label}: the Free Apple ID copy advertises \"Weekly refresh\", but renewal "
            "is manual in this build; the method picker would promise an automatic "
            "capability that does not exist."
        )

# 6. The design note is the reason the gate is closed; it must not go stale.
if doc and "Status: not implemented" in doc and native_integrated:
    problems.append("docs/NATIVE_SIGNING_HANDOFF.md says not implemented while the capability claims .implemented")

print(f"nativeAppleAccountSigning: {'implemented' if native_integrated else 'notIntegrated'}")
print(f"app adapter present:       {'yes' if has_app_adapter else 'no'}")
print(f"profile export present:    {'yes' if has_profile_export else 'no'}")
print(f"UI explains the gap:       {'yes' if says_not_enabled else 'no'}")

if problems:
    print("\nPROBLEMS:")
    for problem in problems:
        print(" -", problem)
    sys.exit(1)
print("\nnative-signing capability matches its wiring")
