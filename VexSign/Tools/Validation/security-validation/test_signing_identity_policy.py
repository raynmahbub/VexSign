#!/usr/bin/env python3
"""Regression guard: the signing identity seam and the nested-bundle views must agree.

Two drifts are pinned here because both were found by reading call sites rather than by any
existing check, and both fail silently:

* A PKCS#12 that carries a certificate but no usable private key is not an identity. Substituting
  `Data()` for the missing key lets one travel to the signer and fail far from the import that
  caused it.
* The signed tree is described in three places — the engine that signs it, the pre-sign audit that
  judges profile coverage, and the post-sign verifier that reports what is wrong. When the lists
  disagree, a nested bundle can be signed and audited but never verified.
"""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[4]
PKCS12 = ROOT / "VexSign/Packages/SideSign/Sources/Certificates/PKCS12Parser.swift"
KEYSTORE = ROOT / "VexSign/Packages/SideSign/Sources/Models/KeyStore.swift"
VERIFIER = ROOT / "VexSign/App/iOS/VexSign/Infrastructure/Signing/Verification/SignatureVerifier.swift"
AUDIT = ROOT / "VexSign/App/iOS/VexSign/Infrastructure/Signing/Verification/NestedBundleAudit.swift"
ENGINE = ROOT / "VexSign/Packages/Vendor/Zsign/src/bundle.cpp"
PLAN = ROOT / "VexSign/App/iOS/VexSign/Infrastructure/Signing/Planning/SigningPlan.swift"
EXECUTABLE_AUDIT = ROOT / "VexSign/App/iOS/VexSign/Infrastructure/Signing/Verification/BundleExecutableAudit.swift"
SEALS = ROOT / "VexSign/App/iOS/VexSign/Infrastructure/Signing/Verification/SignatureVerifier+Seals.swift"
SESSION = ROOT / "VexSign/App/iOS/VexSign/Infrastructure/Signing/Planning/SigningResolutionSession.swift"


def _quoted(pattern: str, source: str) -> list[str]:
    return re.findall(pattern, source)


def _engine_scope() -> tuple[set[str], set[str]]:
    """The nested code `ZBundle::GetObjectsToSign` signs, as (bundle suffixes, file suffixes).

    The function makes two separate passes over the tree: a recursive walk that collects bundles
    to sign as folders, then a flat enumeration that collects loose Mach-O files to sign in place.
    Splitting at the walk's entry point keeps the two lists from being read as one.
    """
    body = re.search(r"GetObjectsToSign.*?^\}", ENGINE.read_text(), re.DOTALL | re.MULTILINE).group(0)
    walk, _, flat = body.partition("findAllBundles(strFolder);")
    suffixes = r'CodeSuffix\(strPath, "\.([^"]+)"\)'
    return set(_quoted(suffixes, walk)), set(_quoted(suffixes, flat))


class SigningIdentityPolicyTests(unittest.TestCase):
    def test_a_missing_private_key_is_rejected_instead_of_substituted(self) -> None:
        source = PKCS12.read_text()
        self.assertNotIn("?? Data()", source,
                         "an absent private key must not become an empty one")
        self.assertIn("guard let keyDER = parser.privateKeyDER, !keyDER.isEmpty else", source)
        self.assertIn("contains a certificate but no private key", source)
        self.assertIn("return (certDER, keyDER)", source)

    def test_a_specific_import_failure_keeps_its_own_cause(self) -> None:
        # Re-wrapping a CertificateError in another CertificateError produced
        # "PKCS#12 import failed: PKCS#12 import failed: ...", which buries the reason.
        source = PKCS12.read_text()
        self.assertIn("catch let error as CertificateError", source)
        self.assertIn("case pkcs12ImportFailed(cause: String)",
                      (ROOT / "VexSign/Packages/SideSign/Sources/Models/Errors.swift").read_text())

    def test_the_only_p12_construction_path_goes_through_the_guarded_parser(self) -> None:
        source = KEYSTORE.read_text()
        self.assertIn("try PKCS12Parser.extract(p12Data, password: password)", source)
        self.assertIn("self.privateKey = result.key", source)


class NestedBundlePolicyTests(unittest.TestCase):
    def test_admission_and_both_verifier_modes_share_the_recursive_manifest(self) -> None:
        for owner in [AUDIT, VERIFIER, EXECUTABLE_AUDIT, SEALS, SESSION]:
            self.assertIn("SigningPlan.make(appBundle:", owner.read_text(), str(owner))
        self.assertNotIn("nestedBundleFolders", VERIFIER.read_text())
        self.assertIn("plan.profileBoundComponents", SESSION.read_text())
        self.assertIn("plan.components.filter { !$0.isResourceOnly }", SEALS.read_text())

    def test_the_manifest_and_verifier_cover_the_native_discovery_scope(self) -> None:
        folders, files = _engine_scope()
        self.assertEqual(folders, {"app", "appex", "framework", "bundle"}, folders)
        self.assertEqual(files, {"dylib"}, files)
        source = PLAN.read_text()
        switches = re.findall(r'case ((?:"[^"]+"(?:, )?)+):', source)
        admitted = {value for branch in switches for value in re.findall(r'"([^"]+)"', branch)}
        self.assertTrue(folders <= admitted, folders - admitted)
        self.assertIn('file.pathExtension.lowercased() == "dylib"', source)
        # Dylibs are independently read as Mach-O images, not Bundle(url:).
        self.assertIn("component.kind == .dylib ? url", EXECUTABLE_AUDIT.read_text())
        self.assertIn("let executable = isDylib ? url", SEALS.read_text())
        self.assertIn("for image in images", SEALS.read_text())

    def test_test_and_xpc_bundles_are_explicitly_blocked_not_omitted(self) -> None:
        source = PLAN.read_text()
        self.assertRegex(source, r'case "xpc", "xctest":\s*fail\(path,')
        self.assertIn("discoveryIssues.map", source)
        self.assertIn("severity: .blocking", source)
        # Native discovery no longer signs xctest while the verifier exempts it.
        folders, _ = _engine_scope()
        self.assertTrue({"xpc", "xctest"}.isdisjoint(folders))

    def test_case_normalization_and_nearest_component_asset_inheritance_are_pinned(self) -> None:
        source = ENGINE.read_text()
        self.assertIn("std::tolower(c)", source)
        self.assertIn("AssetForPath(strFile)", source)
        self.assertIn("AssetForPath(strFolder)", source)
        self.assertIn('binding.first + "/"', source)
        self.assertIn("binding.first.size() > longest", source)
        self.assertIn("Missing explicit component signing inputs", source)

    def test_the_engine_signs_the_whole_tree_rather_than_a_fixed_folder_list(self) -> None:
        # If this ever stops being true, the folder lists above become the engine's real scope and
        # the two tests have to be rewritten against it.
        body = re.search(r"GetObjectsToSign.*?^\}", ENGINE.read_text(), re.DOTALL | re.MULTILINE).group(0)
        self.assertIn("findAllBundles(strPath)", body)
        self.assertNotIn('"Frameworks"', body)
        self.assertNotIn('"PlugIns"', body)


class SigningReadinessWiringTests(unittest.TestCase):
    def test_checklist_action_and_review_share_one_completed_readiness_policy(self):
        screen = (ROOT / "VexSign/App/iOS/VexSign/Presentation/Features/Signing/Views/SigningView.swift").read_text()
        review = (ROOT / "VexSign/App/iOS/VexSign/Presentation/Features/Signing/Views/SigningPreflightReviewView.swift").read_text()
        self.assertIn("let readiness = _currentReadiness", screen)
        self.assertIn("readiness: _currentReadiness", screen)
        self.assertIn(".disabled(!_currentReadiness.canApprove)", screen)
        self.assertIn(".disabled(!readiness.canApprove)", review)
        self.assertNotIn("SigningIdentityPolicy.rejection", screen,
            "A selected row is not the authenticated identity chosen by inventory resolution")
        self.assertNotIn("identifierSuggestion:", screen)
        self.assertNotIn("_provisioningIdentifier", screen)
        self.assertIn("Review Signing Issues", screen)

    def test_changed_inputs_and_cancelled_inspections_cannot_enable_an_old_approval(self):
        screen = (ROOT / "VexSign/App/iOS/VexSign/Presentation/Features/Signing/Views/SigningView.swift").read_text()
        review = (ROOT / "VexSign/App/iOS/VexSign/Presentation/Features/Signing/Views/SigningPreflightReviewView.swift").read_text()
        for token in ["_readinessInput == _inspectionInput", ".task(id: _inspectionInput)",
                      "input == _inspectionInput", "!Task.isCancelled", "_reviewedAuthorization == _currentReadiness.resolution?.authorization"]:
            self.assertIn(token, screen)
        for token in ["pendingAuthorization == resolution?.authorization", "pendingSetup?.matches(", "guard approvalStillMatches"]:
            self.assertIn(token, review)
        self.assertNotIn(".task(id: options)", review,
            "A second independently owned inspection can disagree with the main action panel")

    def test_profile_mismatch_diagnostics_name_the_actual_authorization_without_renaming(self):
        source = (ROOT / "VexSign/App/iOS/VexSign/Domain/Services/CompatibleIdentityResolver.swift").read_text()
        for token in ["profile.Name", "appID", "target.bundleIdentifier", "identifiers will not be changed"]:
            self.assertIn(token, source)
        screen = (ROOT / "VexSign/App/iOS/VexSign/Presentation/Features/Signing/Views/SigningView.swift").read_text()
        self.assertIn("[issue.detail, issue.remediation]", screen)
        self.assertIn("component.issues", screen)


class SigningCredentialAndOutputWiringTests(unittest.TestCase):
    """Source wiring only; behavioral Security/Core Data cases live in XCTest."""

    def test_inventory_cannot_turn_an_unavailable_keychain_into_an_empty_password(self):
        source = (ROOT / "VexSign/App/iOS/VexSign/Infrastructure/Identity/SigningIdentityStore.swift").read_text()
        self.assertIn("password = try passwordReader(row)", source)
        self.assertIn("currentPassword = try passwordReader(row)", source)
        self.assertNotIn('row.signingPassword ?? ""', source)
        self.assertIn("let password = original.password, password == currentPassword", source)
        self.assertIn("if hasValidUUID", source)

    def test_password_migration_never_saves_the_callers_context_or_lossily_decodes_a_secret(self):
        source = (ROOT / "VexSign/App/iOS/VexSign/Security/Certificates/CertificateSecrets.swift").read_text()
        self.assertIn("String(data: stored, encoding: .utf8)", source)
        self.assertNotIn("String(decoding: stored", source)
        self.assertIn("transaction.performAndWait", source)
        self.assertIn("try save(transaction)", source)
        self.assertNotIn("managedObjectContext?.save()", source)
        self.assertNotIn("try context.save()", source)

    def test_fresh_signatures_require_the_complete_verdict_before_registration(self):
        handler = (ROOT / "VexSign/App/iOS/VexSign/Infrastructure/Signing/Execution/SigningHandler.swift").read_text()
        verifier = (ROOT / "VexSign/App/iOS/VexSign/Infrastructure/Signing/Verification/SignatureVerifier.swift").read_text()
        self.assertIn("try report.requireVerified()", handler)
        self.assertLess(handler.index("try _verifySignedBundle("), handler.index("try await self.move()"))
        self.assertIn("func requireVerified() throws", verifier)
        self.assertIn("guard verdict.isVerified else", verifier)


if __name__ == "__main__":
    unittest.main()
