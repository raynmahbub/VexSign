import Foundation
import XCTest
@testable import VexSign

@MainActor
final class SecurityDiagnosticsTests: XCTestCase {
    func testChecksReportUnsupportedInsteadOfClaimingAVerdict() {
        let service = SecurityDiagnosticsService(
            allowInsecureHTTP: false,
            logProbe: { LogRedaction.redact("probe token=not-a-real-token") },
            supportedOSVersion: "18.0"
        )
        let checks = service.checks()
        XCTAssertEqual(
            Set(checks.map(\.id)),
            Set(["transport", "signature", "profile", "archive", "manifest", "logging"])
        )
        XCTAssertFalse(checks.isEmpty)
        for check in checks {
            XCTAssertFalse(check.detail.isEmpty, check.id)
        }
        let signature = checks.first { $0.id == "signature" }
        XCTAssertEqual(signature?.status, .unsupported)
        XCTAssertEqual(checks.first { $0.id == "logging" }?.status, .passed)
    }

    func testInsecureHTTPOptInIsAWarningNotAPass() {
        let service = SecurityDiagnosticsService(
            allowInsecureHTTP: true,
            logProbe: { LogRedaction.redact("probe token=not-a-real-token") },
            supportedOSVersion: "18.0"
        )
        XCTAssertEqual(service.checks().first { $0.id == "transport" }?.status, .warning)
    }

    func testBrokenRedactionIsReportedAsAFailure() {
        let service = SecurityDiagnosticsService(
            allowInsecureHTTP: false,
            logProbe: { "probe token=not-a-real-token" },
            supportedOSVersion: "18.0"
        )
        XCTAssertEqual(service.checks().first { $0.id == "logging" }?.status, .failed)
    }

    func testMalformedProfileIsReportedAsAFailure() {
        let service = SecurityDiagnosticsService(
            allowInsecureHTTP: false,
            profileData: { Data("not a CMS profile".utf8) },
            logProbe: { LogRedaction.redact("probe token=not-a-real-token") },
            supportedOSVersion: "18.0"
        )
        XCTAssertEqual(service.checks().first { $0.id == "profile" }?.status, .failed)
    }
}
