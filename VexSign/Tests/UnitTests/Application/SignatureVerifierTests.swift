import XCTest
@testable import VexSign

/// These non-runnable fixtures intentionally lack a cryptographic code seal.
/// Structural import evidence must never masquerade as a fresh signed success.
/// Directory/resource/CMS checks have their own positive and tamper regressions.
final class SignatureVerifierTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Verifier-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(at: root) }
        root = nil
    }

    private func bundle(signs: Bool = true) throws -> URL {
        try SigningRegressionFixture.bundle(at: root.appendingPathComponent("Fixture.app"), signs: signs)
    }

    private func imported(_ url: URL) -> SignatureVerifier.Report {
        SignatureVerifier.verify(bundleAt: url, expectation: .alreadySigned)
    }

    func testEntitlementOnlyFixtureCannotPassFreshVerificationWithoutAuthenticatedAssets() throws {
        let report = SignatureVerifier.verify(bundleAt: try bundle())
        XCTAssertFalse(report.isAcceptable)
        XCTAssertEqual(report.verdict, .invalid)
        XCTAssertTrue(report.failures.contains { $0.code == .expectedAssetsMissing })
        XCTAssertThrowsError(try report.requireAcceptable(overridingBlockingIssues: true))
    }

    func testFreshVerificationStillRejectsEntitlementOnlyBlobWhenAnExpectationIsSupplied() throws {
        let url = try bundle()
        var expectation = SignatureVerifier.Expectation.freshlySigned
        expectation.assets["."] = .init(bundleIdentifier: "com.example.app", certificateFingerprint: "not-an-identity",
            teamIdentifier: SigningRegressionFixture.team, profileDigest: "not-a-profile", entitlements: [:])
        let report = SignatureVerifier.verify(bundleAt: url, expectation: expectation)
        XCTAssertFalse(report.isAcceptable)
        XCTAssertTrue(report.failures.contains { $0.code == .signatureInvalid || $0.code == .resourceSealInvalid })
        XCTAssertThrowsError(try report.requireAcceptable(overridingBlockingIssues: true))
    }

    func testImportedStructureIsIncompleteNotCryptographicallyVerified() throws {
        let report = imported(try bundle())
        XCTAssertTrue(report.failures.isEmpty, report.summary)
        XCTAssertTrue(report.isAcceptable)
        XCTAssertEqual(report.verdict, .incomplete)
        XCTAssertFalse(report.verdict.isVerified)
        XCTAssertTrue(report.warnings.contains { $0.code == .inspectionOnly })
    }

    func testVerificationReadsCurrentIdentifierInsteadOfBundleCache() throws {
        let url = try bundle(), cached = Bundle(url: root.appendingPathComponent("Fixture.app"))
        _ = cached?.bundleIdentifier
        var info = try XCTUnwrap(SignatureVerifier.readInfo(at: url))
        info["CFBundleIdentifier"] = "com.example.changed"
        try SigningRegressionFixture.plist(info).write(to: url.appendingPathComponent("Info.plist"))
        var expectation = SignatureVerifier.Expectation.alreadySigned
        expectation.declaredBundleIdentifier = "com.example.changed"
        let current = SignatureVerifier.verify(bundleAt: url, expectation: expectation)
        XCTAssertFalse(current.failures.contains { $0.code == .requestedIdentifierMismatch })
        expectation.declaredBundleIdentifier = "com.example.old"
        let mismatch = SignatureVerifier.verify(bundleAt: url, expectation: expectation)
        XCTAssertTrue(mismatch.failures.contains { $0.code == .requestedIdentifierMismatch })
        XCTAssertThrowsError(try mismatch.requireAcceptable())
        withExtendedLifetime(cached) {}
    }

    func testRawXMLExactAndWildcardProfilesAreNeverAuthenticated() throws {
        let url = try bundle()
        for pattern in [SigningRegressionFixture.team + ".com.example.app", SigningRegressionFixture.team + ".*",
                        SigningRegressionFixture.team + ".com.example.*"] {
            let profile = try SigningRegressionFixture.profile(pattern: pattern)
            try SigningRegressionFixture.unsignedProfileData(profile).write(to: url.appendingPathComponent("embedded.mobileprovision"))
            let report = imported(url)
            XCTAssertTrue(report.failures.contains { $0.code == .profileUnreadable }, pattern)
            XCTAssertFalse(report.verdict.isVerified)
            XCTAssertThrowsError(try report.requireAcceptable(overridingBlockingIssues: true))
        }
    }

    func testArbitraryXMLDatesCannotCreateExpiredOrValidAuthenticationEvidence() throws {
        let url = try bundle()
        var profile = try SigningRegressionFixture.profile()
        profile.ExpirationDate = .distantPast
        try SigningRegressionFixture.unsignedProfileData(profile).write(to: url.appendingPathComponent("embedded.mobileprovision"))
        let report = imported(url)
        XCTAssertTrue(report.failures.contains { $0.code == .profileUnreadable })
        XCTAssertFalse(report.issues.contains { $0.code == .profileExpired }, "An unauthenticated field is not trusted expiry evidence.")
    }

    func testMissingProfileIsPermittedOnlyForExplicitStructuralImportInspection() throws {
        let url = try bundle()
        let inspected = imported(url)
        XCTAssertFalse(inspected.failures.contains { $0.code == .profileMissing })
        var required = SignatureVerifier.Expectation.alreadySigned
        required.requiresEmbeddedProfile = true
        let missing = SignatureVerifier.verify(bundleAt: url, expectation: required)
        XCTAssertTrue(missing.failures.contains { $0.code == .profileMissing })
        XCTAssertThrowsError(try missing.requireAcceptable())
    }

    func testDeletingCodeResourcesIsBlockingEvenDuringImportInspection() throws {
        let url = try bundle()
        try FileManager.default.removeItem(at: url.appendingPathComponent("_CodeSignature"))
        let report = imported(url)
        XCTAssertTrue(report.failures.contains { $0.code == .missingCodeResources })
        XCTAssertThrowsError(try report.requireAcceptable(overridingBlockingIssues: true))
    }

    func testCodeResourcesMustBeAContainedFileNotADirectoryOrLink() throws {
        let url = try bundle(), resources = url.appendingPathComponent("_CodeSignature/CodeResources")
        try FileManager.default.removeItem(at: resources)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: false)
        XCTAssertTrue(imported(url).failures.contains { $0.code == .missingCodeResources })
        try FileManager.default.removeItem(at: resources)
        let outside = root.appendingPathComponent("outside-resources")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: resources, withDestinationURL: outside)
        XCTAssertTrue(imported(url).failures.contains { $0.code == .missingCodeResources })
        XCTAssertEqual(try Data(contentsOf: outside), Data("outside".utf8))
    }

    func testUnsignedMainAndLooseDylibAreBlocking() throws {
        let url = try bundle(signs: false)
        XCTAssertTrue(imported(url).failures.contains { $0.code == .unsignedExecutable })
        let directory = url.appendingPathComponent("Unusual/Deep")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try SigningRegressionFixture.machO(fileType: 6).write(to: directory.appendingPathComponent("Loose.DYLIB"))
        XCTAssertTrue(imported(url).failures.contains { $0.code == .unsignedExecutable && $0.subject == "Unusual/Deep/Loose.DYLIB" })
    }

    func testRecursiveManifestFindsUnsignedExtensionsOutsideStandardFolders() throws {
        let url = try bundle()
        try SigningRegressionFixture.bundle(at: url.appendingPathComponent("Odd/Deep/Widget.APPEX"),
            identifier: "com.example.app.widget", signs: false)
        let report = imported(url)
        XCTAssertTrue(report.failures.contains { $0.code == .unsignedNestedBundle && $0.subject == "Widget.APPEX" })
        XCTAssertThrowsError(try report.requireAcceptable(overridingBlockingIssues: true))
    }

    func testWatchCompanionIsNotInvisibleAndNotClaimedAuthorizedByPhoneEvidence() throws {
        let url = try bundle()
        try SigningRegressionFixture.bundle(at: url.appendingPathComponent("Watch/Companion.app"),
            identifier: "com.example.app.watch", signs: false, platform: 4)
        let report = imported(url)
        XCTAssertTrue(report.failures.contains { $0.code == .unsignedNestedBundle && $0.subject == "Companion.app" })
        XCTAssertFalse(report.verdict.isVerified)
    }

    func testMissingFrameworkBinaryIsNotResourceOnlyEvidence() throws {
        let url = try bundle(), framework = url.appendingPathComponent("Frameworks/Broken.framework")
        try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
        try SigningRegressionFixture.plist(["CFBundlePackageType": "FMWK", "CFBundleIdentifier": "org.vendor.Broken",
            "CFBundleExecutable": "Broken"]).write(to: framework.appendingPathComponent("Info.plist"))
        let report = imported(url)
        XCTAssertTrue(report.failures.contains { $0.code == .manifestInvalid })
        XCTAssertTrue(report.failures.contains { $0.code == .unsignedNestedBundle })
    }

    func testPositiveResourceOnlyEvidenceIsSealedByParentNotTreatedAsUnsignedCode() throws {
        let url = try bundle(), resources = url.appendingPathComponent("Frameworks/Resources.framework")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try SigningRegressionFixture.plist(["CFBundlePackageType": "BNDL", "CFBundleIdentifier": "org.vendor.resources"])
            .write(to: resources.appendingPathComponent("Info.plist"))
        try Data([1, 2, 3]).write(to: resources.appendingPathComponent("image.dat"))
        XCTAssertTrue(SigningPlan.isResourceOnlyBundle(resources))
        let report = imported(url)
        XCTAssertFalse(report.failures.contains { $0.code == .unsignedNestedBundle || $0.code == .manifestInvalid })
        XCTAssertEqual(report.verdict, .incomplete)
    }

    func testExternalExecutableLinkAndPathTraversalAreRejectedWithoutTouchingSource() throws {
        let url = try bundle(), executable = url.appendingPathComponent("Fixture"), outside = root.appendingPathComponent("source")
        try FileManager.default.moveItem(at: executable, to: outside)
        try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: outside)
        XCTAssertTrue(imported(url).failures.contains { $0.code == .executableMissing })
        var info = try XCTUnwrap(SignatureVerifier.readInfo(at: url))
        info["CFBundleExecutable"] = "../source"
        try SigningRegressionFixture.plist(info).write(to: url.appendingPathComponent("Info.plist"))
        XCTAssertTrue(imported(url).failures.contains { $0.code == .executableMissing })
        XCTAssertFalse(try Data(contentsOf: outside).isEmpty)
    }

    func testMissingBundleAndIdentifierNeverSurviveOverride() throws {
        let missing = SignatureVerifier.verify(bundleAt: root)
        XCTAssertNil(missing.bundlePath)
        XCTAssertEqual(missing.verdict, .unsupported)
        XCTAssertThrowsError(try missing.requireAcceptable(overridingBlockingIssues: true))
        let url = try bundle()
        var info = try XCTUnwrap(SignatureVerifier.readInfo(at: url)); info["CFBundleIdentifier"] = ""
        try SigningRegressionFixture.plist(info).write(to: url.appendingPathComponent("Info.plist"))
        XCTAssertTrue(imported(url).failures.contains { $0.code == .bundleIdentifierMissing })
    }

    func testNoCapabilityHasAToleratedBypass() {
        XCTAssertTrue(SignatureVerifier.tolerantEntitlementKeys.isEmpty)
        for key in ["keychain-access-groups", "dynamic-codesigning", "com.apple.security.cs.allow-jit", "get-task-allow"] {
            XCTAssertEqual(ProfileEntitlementAuthorization.failures(requested: [key: true], grants: [:]), [key])
        }
    }

    func testLeafCertificateValidityUsesAnExplicitBoundaryNotUnknownExpiryGuessing() throws {
        let expiry = SigningRegressionFixture.now
        XCTAssertNil(SignatureVerifier.certificateExpiryIssue(signatureExpiry: nil, now: .distantFuture))
        XCTAssertNil(SignatureVerifier.certificateExpiryIssue(signatureExpiry: expiry, now: expiry.addingTimeInterval(-1)))
        let issue = try XCTUnwrap(SignatureVerifier.certificateExpiryIssue(signatureExpiry: expiry, now: expiry))
        XCTAssertEqual(issue.code, .certificateExpired)
        XCTAssertEqual(issue.severity, .failure)
    }

    func testMandatoryAndCompatibilityFailuresCannotBeOverridden() {
        let codes: [SignatureVerifier.Issue.Code] = [.bundleNotFound, .executableMissing, .bundleIdentifierMissing,
            .missingCodeResources, .unsignedExecutable, .unsignedNestedBundle, .requestedIdentifierMismatch,
            .profileMissing, .profileUnreadable, .profileExpired, .profileIdentifierUnknown, .entitlementUnreadable,
            .certificateExpired, .bundleIdentifierMismatch, .nestedIdentifierUncovered, .entitlementNotGranted,
            .manifestInvalid, .expectedAssetsMissing, .signatureInvalid, .resourceSealInvalid, .signerMismatch, .profileChanged]
        for code in codes {
            let report = SignatureVerifier.Report(bundlePath: "/test.app",
                issues: [.init(code: code, severity: .failure, detail: code.rawValue)], duration: 0)
            XCTAssertEqual(report.verdict, .invalid)
            XCTAssertTrue(report.stopsRun(overridingBlockingIssues: false), code.rawValue)
            XCTAssertTrue(report.stopsRun(overridingBlockingIssues: true), code.rawValue)
            XCTAssertThrowsError(try report.requireAcceptable(overridingBlockingIssues: true), code.rawValue)
        }
    }

    func testEvidenceGapIsNeverDescribedAsVerified() {
        for code in [SignatureVerifier.Issue.Code.profileUnreadable, .profileIdentifierUnknown, .entitlementUnreadable, .inspectionOnly] {
            let report = SignatureVerifier.Report(bundlePath: "/test.app",
                issues: [.init(code: code, severity: .warning, detail: code.rawValue)], duration: 0)
            XCTAssertEqual(report.verdict, .incomplete)
            XCTAssertFalse(report.verdict.isVerified)
        }
    }

    func testFreshOutputRequiresVerifiedEvidenceWhileImportInspectionCanRemainIncomplete() throws {
        let complete = SignatureVerifier.Report(bundlePath: "/synthetic.app", issues: [], duration: 0)
        XCTAssertNoThrow(try complete.requireVerified())
        let incomplete = SignatureVerifier.Report(bundlePath: "/synthetic.app",
            issues: [.init(code: .inspectionOnly, severity: .warning, detail: "Inspection only")], duration: 0)
        XCTAssertNoThrow(try incomplete.requireAcceptable(overridingBlockingIssues: true))
        XCTAssertThrowsError(try incomplete.requireVerified())
        let invalid = SignatureVerifier.Report(bundlePath: "/synthetic.app",
            issues: [.init(code: .signatureInvalid, severity: .failure, detail: "Invalid synthetic signature")], duration: 0)
        XCTAssertThrowsError(try invalid.requireVerified())
        let unsupported = SignatureVerifier.Report(bundlePath: nil, issues: [], duration: 0)
        XCTAssertThrowsError(try unsupported.requireVerified())
        // A fabricated value above is a policy test, not a real verified bundle.
    }

    func testCoverageKeepsTheOriginalApplicationAndExtensionIdentifiers() {
        let incompatible = "N2998T85B9.app.vanilla7419.emerald5335"
        for identifier in ["app.aidoku.Aidoku", "app.batsign.ios", "app.batsign.ios.status"] {
            XCTAssertFalse(SignatureVerifier.coverage(of: incompatible, includes: identifier), identifier)
        }
        XCTAssertTrue(SignatureVerifier.coverage(of: "TESTTEAM00.com.example.*", includes: "com.example.app.widget"))
        XCTAssertFalse(SignatureVerifier.coverage(of: "TESTTEAM00.com.example.*", includes: "com.example"))
        XCTAssertFalse(SignatureVerifier.coverage(of: "TESTTEAM00.com.example.*", includes: "com.examples.app"))
    }
    func testFreshModeUsesIndependentCryptographicSealsNotImportStructure() throws {
        let source = try RepositorySourceFixture.read("VexSign/App/iOS/Infrastructure/Signing/Verification/SignatureVerifier.swift")
        let fresh = try XCTUnwrap(source.range(of: "if expectation.expectsSignature && expectation.expectsFreshSignature"))
        let structural = try XCTUnwrap(source.range(of: "issues += _signatureIssues"))
        XCTAssertLessThan(fresh.lowerBound, structural.lowerBound)
        let body = source[fresh.lowerBound..<structural.lowerBound]
        XCTAssertTrue(body.contains("freshSealIssues(in: bundleURL, assets: expectation.assets)"))
        XCTAssertTrue(body.contains("return Report"), "Fresh admission must not fall through into import-only inspection.")
    }

}
