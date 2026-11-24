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
import base64
import hashlib
import json
import plistlib
import struct
import re
import unittest


ROOT = Path(__file__).resolve().parents[3]
PKCS12 = ROOT / "Packages/SideSign/Sources/Certificates/PKCS12Parser.swift"
KEYSTORE = ROOT / "Packages/SideSign/Sources/Models/KeyStore.swift"
VERIFIER = ROOT / "VexSign/Services/Signing/Verification/SignatureVerifier.swift"
AUDIT = ROOT / "VexSign/Services/Signing/Verification/NestedBundleAudit.swift"
ENGINE = ROOT / "Packages/Vendor/Zsign/src/bundle.cpp"
PLAN = ROOT / "VexSign/Services/Signing/Planning/SigningPlan.swift"
EXECUTABLE_AUDIT = ROOT / "VexSign/Services/Signing/Verification/BundleExecutableAudit.swift"
SEALS = ROOT / "VexSign/Services/Signing/Verification/SignatureVerifier+Seals.swift"
SESSION = ROOT / "VexSign/Services/Signing/Planning/SigningResolutionSession.swift"


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
                      (ROOT / "Packages/SideSign/Sources/Models/Errors.swift").read_text())

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

    def test_explicit_native_renames_share_the_swift_prefix_boundary(self) -> None:
        native = ENGINE.read_text()
        self.assertIn('const string prefix = oldBase + "."', native)
        self.assertIn('identifier.compare(0, prefix.size(), prefix)', native)
        self.assertIn('newBase + identifier.substr(oldBase.size())', native)
        self.assertEqual(native.count('= RewrittenBundleIdentifier('), 3)
        rewrite = AUDIT.read_text().split('static func rewrittenIdentifier(', 1)[1].split('// MARK:', 1)[0]
        self.assertIn('identifier.hasPrefix(oldBase + ".")', rewrite)
        self.assertNotIn('replacingOccurrences', rewrite)

    def test_the_engine_signs_the_whole_tree_rather_than_a_fixed_folder_list(self) -> None:
        # If this ever stops being true, the folder lists above become the engine's real scope and
        # the two tests have to be rewritten against it.
        body = re.search(r"GetObjectsToSign.*?^\}", ENGINE.read_text(), re.DOTALL | re.MULTILINE).group(0)
        self.assertIn("findAllBundles(strPath)", body)
        self.assertNotIn('"Frameworks"', body)
        self.assertNotIn('"PlugIns"', body)


class SigningReadinessWiringTests(unittest.TestCase):
    def test_checklist_action_and_review_share_one_completed_readiness_policy(self):
        screen = (ROOT / "VexSign/Features/Signing/Views/SigningView.swift").read_text()
        review = (ROOT / "VexSign/Features/Signing/Views/SigningPreflightReviewView.swift").read_text()
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
        screen = (ROOT / "VexSign/Features/Signing/Views/SigningView.swift").read_text()
        review = (ROOT / "VexSign/Features/Signing/Views/SigningPreflightReviewView.swift").read_text()
        for token in ["_readinessInput == _inspectionInput", ".task(id: _inspectionInput)",
                      "input == _inspectionInput", "!Task.isCancelled", "_reviewedAuthorization == _currentReadiness.resolution?.authorization"]:
            self.assertIn(token, screen)
        for token in ["pendingAuthorization == resolution?.authorization", "pendingSetup?.matches(", "guard approvalStillMatches"]:
            self.assertIn(token, review)
        self.assertNotIn(".task(id: options)", review,
            "A second independently owned inspection can disagree with the main action panel")

    def test_profile_mismatch_diagnostics_name_the_actual_authorization_without_renaming(self):
        source = (ROOT / "VexSign/Shared/Services/CompatibleIdentityResolver.swift").read_text()
        for token in ["profile.Name", "appID", "target.bundleIdentifier", "identifiers will not be changed"]:
            self.assertIn(token, source)
        screen = (ROOT / "VexSign/Features/Signing/Views/SigningView.swift").read_text()
        self.assertIn("[issue.detail, issue.remediation]", screen)
        self.assertIn("component.issues", screen)


class PublicSealFixtureTests(unittest.TestCase):
    def test_public_fixture_cms_cdhash_plist_is_independently_readable(self):
        # This is fixture validation, NOT a production CMS verifier or an Apple
        # trust claim. The Objective-C++ bridge performs cryptographic checking.
        value = json.loads((ROOT / "Tests/Support/Fixtures/CodeSignatureCMSFixture.json").read_text())
        executable = base64.b64decode(value['executable'], validate=True)
        little = lambda at: struct.unpack_from('<I', executable, at)[0]
        command = 32
        signature = None
        for _ in range(little(16)):
            if little(command) == 0x1d:
                signature = executable[little(command + 8):little(command + 8) + little(command + 12)]
            command += little(command + 4)
        self.assertIsNotNone(signature)
        word = lambda at: struct.unpack_from('>I', signature, at)[0]
        blobs = {}
        for index in range(word(8)):
            slot, offset = word(12 + index * 8), word(16 + index * 8)
            blobs[slot] = signature[offset:offset + word(offset + 4)]

        def children(encoded):
            offset = 0
            while offset < len(encoded):
                tag = encoded[offset]
                length = encoded[offset + 1]
                header = 2
                if length & 0x80:
                    width = length & 0x7f
                    self.assertTrue(1 <= width <= 4)
                    length = int.from_bytes(encoded[offset + 2:offset + 2 + width], 'big')
                    header += width
                end = offset + header + length
                self.assertLessEqual(end, len(encoded))
                yield tag, encoded[offset + header:end]
                offset = end

        matches = []
        def attributes(encoded, depth=0):
            self.assertLessEqual(depth, 32)
            for tag, content in children(encoded):
                if tag == 0x30:
                    fields = list(children(content))
                    if fields and fields[0] == (0x06, bytes.fromhex('2a864886f763640901')):
                        self.assertEqual(len(fields), 2)
                        values = list(children(fields[1][1]))
                        self.assertEqual(len(values), 1)
                        self.assertEqual(values[0][0], 0x04)
                        matches.append(values[0][1])
                if tag & 0x20:
                    attributes(content, depth + 1)
        attributes(blobs[0x10000][8:])
        self.assertEqual(len(matches), 1)
        self.assertEqual(plistlib.loads(matches[0]), {'cdhashes': [
            hashlib.sha1(blobs[0]).digest(), hashlib.sha256(blobs[0x1000]).digest()[:20]]})


class SigningCredentialAndOutputWiringTests(unittest.TestCase):
    """Source wiring only; behavioral Security/Core Data cases live in XCTest."""

    def test_handoff_authentication_default_stays_closed_and_precedes_key_export(self):
        source = (ROOT / "VexSign/Services/Accounts/NativeSigningManager.swift").read_text()
        body = source.split('struct NativeSigningHandoffCoordinator {', 1)[1].split('// MARK: - NativeSigningManager', 1)[0]
        self.assertIn('try ProvisioningProfileParser.parse($0, now: $1)', body)
        self.assertIn('decoded = try authenticateProfile(profileData, now())', body)
        self.assertLess(body.index('decoded = try authenticateProfile('), body.index('try await exportIdentity(password)'))
        self.assertIn('try NativeSigningHandoffPreflight.validate(decoded', body)
        self.assertNotIn('CertificateReader(', body)
        tests = (ROOT / "Tests/UnitTests/Signing/NativeSigningHandoffPreflightTests.swift").read_text()
        self.assertIn('testDefaultAuthenticatorRejectsUnsignedProfileBeforePrivateKeyExport', tests)
        self.assertIn('authenticateProfile: { data, verificationTime in', tests)
        self.assertNotIn('Data([0x30, 0x03, 0x02, 0x01, 0x00])', tests)

    def test_account_signing_transition_requires_exact_imported_identity_and_separate_review(self):
        source = (ROOT / "VexSign/Features/Signing/Views/SigningView.swift").read_text()
        self.assertIn('return accountHandoff.certificate(in: certificates)', source)
        self.assertIn('guard accountHandoff.matches(app)', source)
        self.assertIn('options.automaticallyResolveSigningIdentity = false', source)
        self.assertIn('options.signingOption = .default', source)
        self.assertIn('guard _accountHandoffIsCurrent else', source)
        contract = (ROOT / 'VexSign/Shared/Protocols/AppleAccountWorkspaceProviding.swift').read_text()
        for condition in ('matches.count == 1', '!candidate.revoked', 'candidate.profile?.ExpirationDate == expiresAt',
                          'candidate.expiration.map({ $0 > now }) == true'):
            self.assertIn(condition, contract)
        importer = (ROOT / 'VexSign/Services/Identity/CertificateManagementService.swift').read_text()
        self.assertLess(importer.index('try await handler.addToDatabase()'), importer.index('completion(.success(handler.certificateUUID))'))
        manager = (ROOT / 'VexSign/Services/Accounts/NativeSigningManager.swift').read_text()
        self.assertIn('continuation.resume(with: $0)', manager)
        self.assertIn('current.id == contextID', manager)

    def test_inventory_cannot_turn_an_unavailable_keychain_into_an_empty_password(self):
        source = (ROOT / "VexSign/Services/Identity/SigningIdentityStore.swift").read_text()
        self.assertIn("password = try passwordReader(row)", source)
        self.assertIn("currentPassword = try passwordReader(row)", source)
        self.assertNotIn('row.signingPassword ?? ""', source)
        self.assertIn("let password = original.password, password == currentPassword", source)
        self.assertIn("if hasValidUUID", source)

    def test_password_migration_never_saves_the_callers_context_or_lossily_decodes_a_secret(self):
        source = (ROOT / "VexSign/Security/Certificates/CertificateSecrets.swift").read_text()
        self.assertIn("String(data: stored, encoding: .utf8)", source)
        self.assertNotIn("String(decoding: stored", source)
        self.assertIn("transaction.performAndWait", source)
        self.assertIn("try save(transaction)", source)
        self.assertNotIn("managedObjectContext?.save()", source)
        self.assertNotIn("try context.save()", source)

    def test_fresh_signatures_require_the_complete_verdict_before_registration(self):
        handler = (ROOT / "VexSign/Services/Signing/Execution/SigningHandler.swift").read_text()
        verifier = (ROOT / "VexSign/Services/Signing/Verification/SignatureVerifier.swift").read_text()
        self.assertIn("try report.requireVerified()", handler)
        self.assertLess(handler.index("try _verifySignedBundle("), handler.index("try await self.move()"))
        self.assertIn("func requireVerified() throws", verifier)
        self.assertIn("guard verdict.isVerified else", verifier)


class DeepLinkCertificateConsentTests(unittest.TestCase):
    """A custom-scheme link must not install a signing identity by itself.

    `vexsign://import-certificate?p12=…&mobileprovision=…&password=…` is reachable from any app or
    web page. Importing stages a `.p12` and commits a row that can sign later installs, so the
    user has to say yes; the files must also be removed once the outcome is known.
    """

    ROUTER = ROOT / "VexSign/Features/Dashboard/UseCases/DeepLinkRouterUseCase.swift"

    def test_the_import_waits_for_a_confirmation(self) -> None:
        source = self.ROUTER.read_text()
        self.assertIn("presentYesNoAlert(", source,
                      "a link-originated certificate import must ask the user first")
        self.assertLess(source.index("presentYesNoAlert("), source.index("self.importCertificateFiles("),
                        "confirmation must come before the importer runs")

    def test_an_invalid_pair_is_rejected_before_the_prompt(self) -> None:
        source = self.ROUTER.read_text()
        self.assertLess(source.index("guard validateCertificatePassword("),
                        source.index("presentYesNoAlert("),
                        "do not prompt for a pair that does not validate")

    def test_the_staged_pair_is_discarded_through_the_port(self) -> None:
        source = self.ROUTER.read_text()
        self.assertIn("incomingFiles.discardTemporaryFile(", source)
        self.assertNotIn("FileManager.default.removeItem", source,
                         "application use cases reach the filesystem through their port")
        self.assertIn("func discardTemporaryFile(_ url: URL)",
                      (ROOT / "VexSign/Shared/Protocols/IncomingFilesProviding.swift").read_text())


class BundledSigningMaterialTests(unittest.TestCase):
    """A private key must never be able to travel inside a build.

    `CertificateAutoImporter` reads `signing-assets/<name>/{cert.p12,cert.mobileprovision,cert.txt}`
    out of the app bundle at launch and imports each folder as the default signing identity. That is
    a developer convenience, but nothing stopped the folder from being committed or added to the
    project: `*.p12` and `*.mobileprovision` are ignored while `cert.txt` — the password in
    plaintext — is not, and no gate looked at the folder at all.
    """

    def test_the_drop_folder_is_ignored_by_git(self) -> None:
        gitignore = (ROOT / ".gitignore").read_text()
        self.assertIn("signing-assets/", gitignore,
                      "the password file (cert.txt) is not covered by *.p12/*.mobileprovision")

    def test_the_drop_folder_cannot_be_bundled_into_a_target(self) -> None:
        project = (ROOT / "VexSign.xcodeproj/project.pbxproj").read_text()
        self.assertNotIn("signing-assets", project,
                         "a certificate folder added to the project ships in every archive")

    def test_no_password_file_is_present_in_a_drop_folder(self) -> None:
        offenders = [str(path.relative_to(ROOT))
                     for path in ROOT.rglob("signing-assets/*/cert.txt")]
        self.assertEqual(offenders, [], "plaintext certificate passwords must not sit in the tree")


if __name__ == "__main__":
    unittest.main()
