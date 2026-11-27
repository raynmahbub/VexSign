//
//  SigningVerificationReportTests.swift
//  VexSignTests
//
//  The persisted verification report is user-facing evidence. It must stay
//  bounded, must not carry engine secrets or private paths, and must never be
//  invented from a stage or a finished run.
//

import Foundation
import XCTest
@testable import VexSign

final class SigningVerificationReportTests: XCTestCase {
    func testEmptyReportIsNotAVerificationVerdict() {
        XCTAssertEqual(SigningVerificationReport.empty.verdict, "unsupported")
        XCTAssertTrue(SigningVerificationReport.empty.issues.isEmpty)
        XCTAssertTrue(SigningVerificationReport.empty.signerFingerprints.isEmpty)
    }

    func testMakeIsBoundedAndRedactsPasswordsAndPrivatePaths() {
        let secret = "password=hunter2 /var/mobile/Containers/Data/Application/01234567-89AB-CDEF-0123-456789ABCDEF/secret"
        let issues = (0..<40).map { index in
            SignatureVerifier.Issue(
                code: .signatureInvalid, severity: .failure,
                detail: "Issue \(index): \(secret) " + String(repeating: "x", count: 400),
                subject: secret
            )
        }
        let source = SignatureVerifier.Report(
            bundlePath: "/private/var/mobile/Containers/Data/Application/fixture/Payload/App.app",
            issues: issues, duration: 12.5
        )

        let report = SigningVerificationReportBuilder.make(
            from: source,
            bundleAt: URL(fileURLWithPath: "/definitely/not/a/bundle"),
            componentCount: 1_000_000,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertEqual(report.verdict, "invalid")
        XCTAssertEqual(report.failureCount, 40)
        XCTAssertEqual(report.warningCount, 0)
        XCTAssertEqual(report.issues.count, 32)
        XCTAssertEqual(report.componentCount, 1024)
        XCTAssertEqual(report.durationMilliseconds, 12_500)
        XCTAssertEqual(report.verifiedAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertTrue(report.issues.allSatisfy { $0.detail.count <= 241 })
        XCTAssertFalse(report.summary.contains(secret))
        XCTAssertFalse(report.issues.contains { $0.detail.contains("hunter2") })
        XCTAssertFalse(report.issues.contains { ($0.subject ?? "").contains("hunter2") })
        XCTAssertFalse(report.issues.contains { ($0.subject ?? "").contains("/var/mobile/") })
    }

    func testReportSurvivesJSONRoundTripWithoutLosingEvidence() throws {
        let report = SigningVerificationReport(
            verdict: "valid", summary: "Signature structure checked in 3 ms.", failureCount: 0,
            warningCount: 1, issues: [.init(code: "profileUnreadable", severity: "warning",
                                            detail: "Profile could not be read.", subject: "embedded.mobileprovision")],
            signerFingerprints: ["AA:BB"], architectureCount: 2, componentCount: 3,
            durationMilliseconds: 3, verifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try JSONEncoder().encode(report)
        XCTAssertEqual(try JSONDecoder().decode(SigningVerificationReport.self, from: data), report)
    }
}
