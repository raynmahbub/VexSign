import XCTest
@testable import VexSign

final class AutoSignIdentityPolicyTests: XCTestCase {
    func testImportedCertificateCanBeUsedUnattended() {
        XCTAssertEqual(
            AutoSignIdentityPolicy.decide(identity: .importedCertificate),
            .allow
        )
    }

    func testAppleAccountNeverUsesAStoredCertificateUnattended() {
        XCTAssertEqual(
            AutoSignIdentityPolicy.decide(identity: .appleAccount),
            .requireAttendedReview
        )
    }

    func testReviewedRefreshIsTheOnlyAppleAccountException() {
        XCTAssertEqual(
            AutoSignIdentityPolicy.decide(identity: .appleAccount, attendedAppleAccountRefresh: true),
            .allow
        )
    }

    func testAnImportedCertificateIsUnaffectedByTheAttendedFlag() {
        XCTAssertEqual(
            AutoSignIdentityPolicy.decide(identity: .importedCertificate, attendedAppleAccountRefresh: true),
            .allow
        )
    }
}
