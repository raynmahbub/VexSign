import XCTest
@testable import VexSign

final class ImportedCertificateRefreshPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func credential(
        profileDays: Int,
        certificateDays: Int? = nil,
        revoked: Bool = false,
        kind: SigningCredentialKind = .importedPair
    ) -> SigningCredential {
        SigningCredential(
            id: "certificate",
            kind: kind,
            name: "Imported",
            teamID: "ABCDEFGHIJ",
            expiresAt: now.addingTimeInterval(Double(profileDays) * 86_400),
            certificateExpiresAt: certificateDays.map { now.addingTimeInterval(Double($0) * 86_400) },
            isRevoked: revoked
        )
    }

    func testImportedCredentialsHaveNoPeriodicRefresh() {
        for kind in SigningCredentialKind.allCases {
            XCTAssertFalse(ImportedCertificateRefreshPolicy.schedulesPeriodicRefresh(for: kind))
        }
    }

    func testWarningUsesTheEarlierOfLeafAndProfileExpiry() {
        XCTAssertEqual(
            ImportedCertificateRefreshPolicy.warning(
                for: credential(profileDays: 200, certificateDays: 10), now: now
            ),
            .soon
        )
        XCTAssertEqual(
            ImportedCertificateRefreshPolicy.warning(for: credential(profileDays: 30), now: now),
            .none
        )
    }

    func testRevocationOutranksExpiryAndCriticalWarnings() {
        XCTAssertEqual(
            ImportedCertificateRefreshPolicy.warning(
                for: credential(profileDays: -1, revoked: true), now: now
            ),
            .revoked
        )
        XCTAssertEqual(
            ImportedCertificateRefreshPolicy.warning(for: credential(profileDays: 2), now: now),
            .critical
        )
        XCTAssertEqual(
            ImportedCertificateRefreshPolicy.warning(for: credential(profileDays: -1), now: now),
            .expired
        )
    }

    func testNotificationLevelsOnlyEscalate() {
        let ordered: [ImportedCertificateWarning] = [.notice, .soon, .critical, .expired]
        let levels = ordered.map { ImportedCertificateRefreshPolicy.notificationLevel(for: $0) }
        XCTAssertEqual(levels, levels.sorted(by: >))
        XCTAssertEqual(ImportedCertificateRefreshPolicy.notificationLevel(for: .revoked), 0)
    }

    func testPlanCarriesRevocationIntoTheWarning() {
        let revokedPlan = RenewalPlanner.plan(
            for: credential(profileDays: 2, revoked: true), now: now
        )
        XCTAssertTrue(revokedPlan.isRevoked)
        XCTAssertEqual(ImportedCertificateRefreshPolicy.warning(for: revokedPlan), .revoked)
    }
}
