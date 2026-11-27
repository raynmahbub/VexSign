#!/usr/bin/env python3
"""Portable regression gates for the security-hardening changes.

These tests do not compile Swift (no Xcode toolchain exists in the portable CI
job). They assert the *wiring* of each protection: the consent callback that
removes staged private keys, the redaction of certificate-link payloads, the
permission cap on extracted archive entries, the HTTPS gate on update assets,
the pinned release-key store, and the diagnostics rows backed by real
validators. The behaviour of the pure Swift policy functions is additionally
covered by VexSignTests; these gates stop a future edit from silently removing
their call sites.

    python3 Tools/Audit/test_security_hardening_contracts.py
"""

from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


def source(path):
    return (ROOT / path).read_text(encoding="utf-8")


class SecurityHardeningContracts(unittest.TestCase):
    def test_declined_certificate_import_removes_staged_private_key(self):
        protocol = source("VexSign/Shared/Protocols/SubsystemBoundaries.swift")
        adapter = source("VexSign/System/URLHandling/UIKitPlatformAdapter.swift")
        router = source("VexSign/Features/Dashboard/UseCases/DeepLinkRouterUseCase.swift")
        self.assertIn("func presentImportConsentAlert(", protocol)
        self.assertIn("onCancel: @escaping () -> Void", protocol)
        self.assertIn("func presentImportConsentAlert(", adapter)
        self.assertIn("alert.addAction(UIAlertAction(title: .localized(\"Cancel\")", adapter)
        self.assertIn("onCancel()", adapter)
        self.assertIn("platform.presentImportConsentAlert(", router)
        consent = router[router.index("platform.presentImportConsentAlert("):]
        self.assertIn("onCancel:", consent)
        discard = consent[consent.index("onCancel:"):]
        self.assertIn("discardStagedCertificateFiles([p12URL, provisionURL])", discard)

        staging = source("Packages/NimbleKit/Sources/NimbleKit/NimbleExtensions/FileManager/FileManager+shortcuts.swift")
        self.assertIn(".completeFileProtection", staging)
        self.assertIn(".posixPermissions: 0o600", staging)
        staging_tests = source("VexSignTests/SecurityTests/URLValidation/DeepLinkBase64StagingTests.swift")
        self.assertIn("testStagedPrivateKeyPayloadIsOwnerOnly", staging_tests)

    def test_certificate_link_payloads_and_forged_lines_are_redacted(self):
        redaction = source("VexSign/Services/Diagnostics/LogRedaction.swift")
        self.assertIn("mobileprovision", redaction)
        self.assertIn("([?&;](?:p12|mobileprovision|certificate_p12|provisioning_profile)=)", redaction)
        self.assertIn('replacingOccurrences(of: "\\n", with: " ↵ ")', redaction)
        tests = source("VexSignTests/SecurityTests/CredentialRedaction/LogRedactionTests.swift")
        self.assertIn("testDeepLinkPrivateKeyAndProfilePayloadsAreMaskedInAQuery", tests)
        self.assertIn("testEmbeddedNewlinesCannotForgeASecondLogLine", tests)

    def test_archive_modes_are_capped_before_they_reach_the_filesystem(self):
        policy = source("VexSign/Security/ArchiveValidation/ArchiveFileAttributesPolicy.swift")
        self.assertIn("static let maximumPermissions: Int = 0o755", policy)
        self.assertIn("declared & 0o777", policy)
        self.assertIn("ordinary & maximumPermissions", policy)
        extractor = source("VexSign/Services/Import/Extraction/IPAExtractor.swift")
        self.assertEqual(extractor.count("ArchiveFileAttributesPolicy.sanitized("), 2,
                         "both directory and file metadata must be sanitized")
        tests = source("VexSignTests/SecurityTests/ArchiveTraversal/ArchiveFileAttributesTests.swift")
        self.assertIn("testSpecialAndGroupWriteBitsAreRemovedFromFiles", tests)

        # Binary cap, not numeric min: 0o764 must become 0o744, not 0o755.
        for declared in (0o4777, 0o2777, 0o1777, 0o777, 0o766, 0o666, 0o600, 0o755):
            self.assertEqual((declared & 0o777) & 0o755, declared & 0o755)

    def test_update_asset_urls_use_the_package_transport_policy(self):
        manager = source("VexSign/Services/Updates/SelfUpdateManager.swift")
        self.assertIn("PackageDownloadURLPolicy.validateInitialURL(candidate)", manager)
        self.assertLess(manager.index("browser_download_url"),
                        manager.index("PackageDownloadURLPolicy.validateInitialURL(candidate)"))

    def test_release_manifest_trust_is_bundled_not_embedded(self):
        store = source("VexSign/Security/Trust/ReleaseManifestTrustStore.swift")
        self.assertIn('static let resourceName = "ReleaseManifestKeys"', store)
        self.assertIn("bundle.url(forResource: resourceName", store)
        self.assertIn("Curve25519.Signing.PublicKey(rawRepresentation: data)", store)
        self.assertNotRegex(store, r'Data\(base64Encoded:\s*"[A-Za-z0-9+/=]{20,}"')
        self.assertIn("struct ReleaseManifestTrustStore", store)

    def test_diagnostics_are_wired_to_real_validators(self):
        service = source("VexSign/Services/Diagnostics/SecurityDiagnosticsService.swift")
        for call in (
            "SignatureVerifier.verify(",
            "ProvisioningProfileParser.parse(",
            "ArchiveSafetyValidator.validate(",
            "ReleaseManifestTrustStore.inspect(",
            "SourceURLPolicy.allowInsecureHTTP",
            "LogRedaction.redact(",
        ):
            self.assertIn(call, service, f"diagnostics lost the {call} check")
        self.assertNotIn("securityScore", service)
        container = source("VexSign/App/Composition/AppContainer.swift")
        self.assertIn("securityProvider: SecurityDiagnosticsService(", container)
        view = source("VexSign/Features/Dashboard/About/DiagnosticsCenterView.swift")
        self.assertIn("Security Verification", view)
        self.assertIn("securitySymbol(check.status)", view)

    def test_log_file_is_restricted_and_app_transport_security_is_not_disabled(self):
        logger = source("VexSign/Services/Diagnostics/FileLogger.swift")
        self.assertIn("ProtectedCertificateFiles.applyProtectionAttributes(", logger)
        self.assertIn("_protect(url, permissions: 0o600)", logger)
        plist = source("Config/BuildSettings/iOS/Info.plist")
        self.assertNotIn("NSAllowsArbitraryLoads", plist)
        self.assertIn("NSAllowsLocalNetworking", plist)


if __name__ == "__main__":
    unittest.main(verbosity=2)
