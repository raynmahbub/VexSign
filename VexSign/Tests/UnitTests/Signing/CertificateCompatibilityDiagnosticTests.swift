import XCTest
@testable import VexSign

final class CertificateCompatibilityDiagnosticTests: XCTestCase {
    func testEveryAuditReasonHasDistinctNonGenericTitleExplanationAndRemediation() {
        var titles = Set<String>()
        var explanations = Set<String>()

        for reason in CertificateCompatibilityDiagnostic.Reason.allCases {
            let diagnostic = CertificateCompatibilityDiagnostic.make(reason: reason)
            XCTAssertFalse(diagnostic.title.isEmpty, "Missing title for \(reason)")
            XCTAssertFalse(diagnostic.explanation.isEmpty, "Missing explanation for \(reason)")
            XCTAssertFalse(diagnostic.remediation.isEmpty, "Missing remediation for \(reason)")
            XCTAssertNotEqual(diagnostic.title.lowercased(), "signing failed")
            XCTAssertNotEqual(diagnostic.explanation.lowercased(), "signing failed.")
            XCTAssertTrue(diagnostic.logLine.contains(reason.rawValue))
            titles.insert(diagnostic.title)
            explanations.insert(diagnostic.explanation)
        }

        XCTAssertEqual(CertificateCompatibilityDiagnostic.Reason.allCases.count, 11)
        XCTAssertEqual(titles.count, 11, "Every failure category must have a distinct title.")
        XCTAssertEqual(explanations.count, 11, "Every failure category must have a distinct explanation.")
    }

    func testImportErrorsMapToExactDiagnosticReasons() {
        let wrongPassword = CertificateImportDiagnosis.diagnostic(
            for: SigningIdentityStore.InspectionFailure.wrongPassword
        )
        XCTAssertEqual(wrongPassword.reason, .wrongPrivateKeyPassword)

        let missingPrivateKey = CertificateImportDiagnosis.diagnostic(
            for: SigningIdentityStore.InspectionFailure.privateKeyMissing
        )
        XCTAssertEqual(missingPrivateKey.reason, .privateKeyUnavailable)

        let expiredProfile = CertificateImportDiagnosis.diagnostic(
            for: CertificateImportDiagnosis.profileExpired(
                name: "DevProfile",
                expiry: Date(timeIntervalSince1970: 1000)
            )
        )
        XCTAssertEqual(expiredProfile.reason, .provisioningProfileExpired)

        let mismatch = CertificateImportDiagnosis.diagnostic(
            for: CertificateImportDiagnosis.identityNotInProfile(commonName: "Apple Dev", profileName: "OtherProfile")
        )
        XCTAssertEqual(mismatch.reason, .certificateProfileMismatch)

        let untrustedCMS = CertificateImportDiagnosis.diagnostic(
            for: ProvisioningProfileParser.Failure.untrustedCMS
        )
        XCTAssertEqual(untrustedCMS.reason, .unsupportedSigningCapability)
    }

    func testPreflightProfileCompatibilityResolutionAndVerifierAgreeAcrossAllFailureModes() {
        // 1. Certificate expired
        XCTAssertEqual(
            SigningCapability.Issue(
                code: .certificateExpired,
                severity: .blocking,
                title: "Expired",
                detail: "Cert expired"
            )
                .compatibilityDiagnostic.reason,
            .certificateExpired
        )
        XCTAssertEqual(
            SigningResolutionIssue(code: .expiration, detail: "The signing certificate has expired.")
                .compatibilityDiagnostic().reason,
            .certificateExpired
        )
        XCTAssertEqual(
            SignatureVerifier.Issue(code: .certificateExpired, severity: .failure, detail: "Expired signer")
                .compatibilityDiagnostic.reason,
            .certificateExpired
        )

        // 2. Certificate revoked
        XCTAssertEqual(
            SigningCapability.Issue(code: .certificateRevoked, severity: .blocking, title: "Revoked", detail: "Revoked")
                .compatibilityDiagnostic.reason,
            .certificateRevoked
        )

        // 3. Provisioning profile expired
        XCTAssertEqual(
            ProfileCompatibility.Issue(code: .profileExpired, severity: .blocking, detail: "Profile expired")
                .compatibilityDiagnostic.reason,
            .provisioningProfileExpired
        )
        XCTAssertEqual(
            SigningCapability.Issue(
                code: .profileExpired,
                severity: .blocking,
                title: "Expired",
                detail: "Profile expired"
            )
                .compatibilityDiagnostic.reason,
            .provisioningProfileExpired
        )
        XCTAssertEqual(
            SigningResolutionIssue(code: .expiration, detail: "Provisioning profile expired.")
                .compatibilityDiagnostic().reason,
            .provisioningProfileExpired
        )
        XCTAssertEqual(
            SignatureVerifier.Issue(code: .profileExpired, severity: .failure, detail: "Profile expired")
                .compatibilityDiagnostic.reason,
            .provisioningProfileExpired
        )

        // 4. Bundle identifier not covered
        XCTAssertEqual(
            ProfileCompatibility.Issue(code: .appIdentifierMismatch, severity: .blocking, detail: "App ID mismatch")
                .compatibilityDiagnostic.reason,
            .bundleIdentifierNotCovered
        )
        XCTAssertEqual(
            SigningResolutionIssue(code: .identifier, detail: "Main app ID not covered")
                .compatibilityDiagnostic(componentPath: ".").reason,
            .bundleIdentifierNotCovered
        )
        XCTAssertEqual(
            SignatureVerifier.Issue(code: .bundleIdentifierMismatch, severity: .failure, detail: "App ID mismatch")
                .compatibilityDiagnostic.reason,
            .bundleIdentifierNotCovered
        )

        // 5. Device not included in profile
        XCTAssertEqual(
            ProfileCompatibility.Issue(code: .deviceNotProvisioned, severity: .blocking, detail: "UDID missing")
                .compatibilityDiagnostic.reason,
            .deviceNotIncludedInProfile
        )
        XCTAssertEqual(
            SigningCapability.Issue(
                code: .deviceNotProvisioned,
                severity: .blocking,
                title: "Device",
                detail: "UDID missing"
            )
                .compatibilityDiagnostic.reason,
            .deviceNotIncludedInProfile
        )
        XCTAssertEqual(
            SigningResolutionIssue(code: .device, detail: "Device UDID not listed")
                .compatibilityDiagnostic().reason,
            .deviceNotIncludedInProfile
        )

        // 6. Entitlement not authorized
        XCTAssertEqual(
            ProfileCompatibility.Issue(code: .entitlementNotGranted, severity: .blocking, detail: "App group missing")
                .compatibilityDiagnostic.reason,
            .entitlementNotAuthorized
        )
        XCTAssertEqual(
            SigningResolutionIssue(code: .entitlement, detail: "Entitlement missing")
                .compatibilityDiagnostic().reason,
            .entitlementNotAuthorized
        )
        XCTAssertEqual(
            SignatureVerifier.Issue(code: .entitlementNotGranted, severity: .failure, detail: "Entitlement missing")
                .compatibilityDiagnostic.reason,
            .entitlementNotAuthorized
        )

        // 7. Nested extension not covered
        XCTAssertEqual(
            ProfileCompatibility.Issue(code: .extensionNotCovered, severity: .blocking, detail: "Widget uncovered")
                .compatibilityDiagnostic.reason,
            .nestedExtensionNotCovered
        )
        XCTAssertEqual(
            SigningResolutionIssue(code: .identifier, detail: "Extension ID uncovered")
                .compatibilityDiagnostic(componentPath: "PlugIns/Widget.appex").reason,
            .nestedExtensionNotCovered
        )
        XCTAssertEqual(
            SignatureVerifier.Issue(
                code: .nestedIdentifierUncovered,
                severity: .failure,
                detail: "Widget uncovered",
                subject: "PlugIns/Widget.appex"
            ).compatibilityDiagnostic.reason,
            .nestedExtensionNotCovered
        )

        // 8. Certificate / provisioning profile mismatch
        XCTAssertEqual(
            ProfileCompatibility.Issue(code: .certificateNotInProfile, severity: .blocking, detail: "Cert mismatch")
                .compatibilityDiagnostic.reason,
            .certificateProfileMismatch
        )
        XCTAssertEqual(
            SigningResolutionIssue(code: .certificate, detail: "Cert not listed in profile")
                .compatibilityDiagnostic().reason,
            .certificateProfileMismatch
        )
        XCTAssertEqual(
            SignatureVerifier.Issue(code: .signerMismatch, severity: .failure, detail: "Signer mismatch")
                .compatibilityDiagnostic.reason,
            .certificateProfileMismatch
        )

        // 9. Unsupported capability
        XCTAssertEqual(
            SigningCapability.Issue(
                code: .executableEncrypted,
                severity: .blocking,
                title: "Encrypted",
                detail: "Encrypted"
            )
                .compatibilityDiagnostic.reason,
            .unsupportedSigningCapability
        )
        XCTAssertEqual(
            SigningResolutionIssue(code: .platform, detail: "Unsupported platform")
                .compatibilityDiagnostic().reason,
            .unsupportedSigningCapability
        )
    }
}
