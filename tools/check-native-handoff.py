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

The seam now exists, so wiring alone is no longer enough to promote it: the
handoff has only ever been exercised against synthetic CMS bytes and injected
import operations. Two observations are still missing — a genuine Apple-issued
profile reaching the pinned production roots, and the physical-device ladder —
and neither can be produced by a code edit. They are recorded instead in
`docs/evidence/native-signing-promotion.json` and checked by
`tools/native-promotion-evidence.py`:

  * `.implemented` without complete, committed evidence fails here;
  * `.implemented` while `SideSignAccountBridge` still defaults to an
    unconfigured `NativeProvisioningProfileValidator` fails here;
  * complete evidence while the flag is still `.notIntegrated` also fails, so
    the flag, the UI copy and the doc move in the same change.

It also keeps the rule that landed with the identity-strategy audit: nothing may
claim that Free Apple ID renewal happens. `renewExpiringProfiles()`,
`renewFreeAppleIDProfiles()`, `supportsAutoRefresh` and the "Weekly refresh"
picker copy each described a capability this build does not have.

This check encodes the current, deliberate state. It is meant to be updated in
the same change that implements the seam — see docs/NATIVE_SIGNING_HANDOFF.md.
"""

from __future__ import annotations

import importlib.util
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# Repository-relative so `evaluate` can run against a scratch checkout in tests.
CAPABILITIES = Path("VexSign/Backend/Services/SigningMethodCapabilities.swift")
MANAGER = Path("VexSign/Backend/Services/NativeSigningManager.swift")
FLOW = Path("VexSign/Views/Settings/ProvisioningFlowView.swift")
BACKEND = Path("NativeSigning/Authentication/NativeAccountBackend.swift")
AUTOMATION = Path("VexSign/Backend/Observable/BackgroundAutomation.swift")
SIGNING_METHOD = Path("VexSign/Backend/Services/SigningMethod.swift")
HANDOFF_DOC = Path("docs/NATIVE_SIGNING_HANDOFF.md")
EVIDENCE_RELATIVE = Path("docs/evidence/native-signing-promotion.json")


def evidence_tool():
    """`native-promotion-evidence.py` owns the evidence vocabulary."""
    path = Path(__file__).with_name("native-promotion-evidence.py")
    spec = importlib.util.spec_from_file_location("native_promotion_evidence_for_gate", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def promotion_evidence(root: Path, module=None) -> tuple[str, list[str]]:
    """Classify the recorded promotion evidence: absent/incomplete/complete/invalid."""
    module = module or evidence_tool()
    path = root / EVIDENCE_RELATIVE
    if not path.is_file():
        return "absent", []
    record, problem = module.load(path)
    if problem:
        return "invalid", [problem]
    errors = module.validate(record, head_commit=module.current_commit(root), root=root)
    return ("complete" if not errors else "incomplete"), errors


def evaluate(root: Path = ROOT) -> tuple[list[str], dict[str, str]]:
    problems: list[str] = []

    def read(relative: Path) -> str:
        path = root / relative
        if not path.is_file():
            problems.append(f"missing file: {relative.as_posix()}")
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
    renewal_claims = {
        "VexSign/Backend/Services/NativeSigningManager.swift": MANAGER,
        "VexSign/Backend/Observable/BackgroundAutomation.swift": AUTOMATION,
        "VexSign/Backend/Services/SigningMethod.swift": SIGNING_METHOD,
    }

    #    Only real code counts. The explanations of *why* the claims were removed name the
    #    old spellings on purpose, so full-line comments are stripped before matching.
    def code_only(text: str) -> str:
        return "\n".join(
            line for line in text.splitlines() if not line.lstrip().startswith(("//", "///"))
        )

    for label, relative in renewal_claims.items():
        path = root / relative
        if not path.is_file():
            continue
        body = code_only(path.read_text())
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
    if doc and "Production gate still closed" in doc and native_integrated:
        problems.append(
            "docs/NATIVE_SIGNING_HANDOFF.md still describes the production CMS gate as closed "
            "while the capability claims .implemented; update the doc in the same change"
        )

    # 7. Wiring is necessary but not sufficient: promotion needs recorded genuine
    #    Apple CMS observations and a complete physical-device ladder.
    evidence = evidence_tool()
    evidence_state, evidence_errors = promotion_evidence(root, evidence)
    verifier_selected = evidence.production_selects_apple_cms(root)

    if native_integrated and not verifier_selected:
        problems.append(
            "nativeAppleAccountSigning is .implemented but SideSignAccountBridge still defaults to an "
            "unconfigured NativeProvisioningProfileValidator; production never verifies Apple CMS"
        )
    if native_integrated and evidence_state != "complete":
        problems.append(
            f"nativeAppleAccountSigning is .implemented but promotion evidence at "
            f"{EVIDENCE_RELATIVE.as_posix()} is {evidence_state}; record genuine Apple CMS and the "
            f"device ladder with tools/native-promotion-evidence.py"
        )
        problems.extend(f"evidence: {error}" for error in evidence_errors[:6])
    if not native_integrated and evidence_state == "complete":
        problems.append(
            f"promotion evidence at {EVIDENCE_RELATIVE.as_posix()} is complete while the capability is "
            f"still .notIntegrated; flip the flag, retire the UI caveat and update the doc in the same change"
        )

    facts = {
        "claim": "implemented" if native_integrated else "notIntegrated",
        "app adapter present": "yes" if has_app_adapter else "no",
        "profile export present": "yes" if has_profile_export else "no",
        "UI explains the gap": "yes" if says_not_enabled else "no",
        "production CMS verifier": "yes" if verifier_selected else "no",
        "promotion evidence": evidence_state,
    }
    return problems, facts


def main() -> int:
    problems, facts = evaluate(ROOT)
    print(f"nativeAppleAccountSigning: {facts['claim']}")
    print(f"app adapter present:       {facts['app adapter present']}")
    print(f"profile export present:    {facts['profile export present']}")
    print(f"UI explains the gap:       {facts['UI explains the gap']}")
    print(f"production CMS verifier:   {facts['production CMS verifier']}")
    print(f"promotion evidence:        {facts['promotion evidence']}")

    if problems:
        print("\nPROBLEMS:")
        for problem in problems:
            print(" -", problem)
        return 1
    print("\nnative-signing capability matches its wiring")
    return 0


if __name__ == "__main__":
    sys.exit(main())
