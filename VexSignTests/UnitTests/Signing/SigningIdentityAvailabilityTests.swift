//
//  SigningIdentityAvailabilityTests.swift
//  VexSignTests
//
//  Sources and paired-device update planning must agree on whether an identity
//  can still be used. No Keychain or account material is needed for these rules.
//

import XCTest
@testable import VexSign

final class SigningIdentityAvailabilityTests: XCTestCase {
    private func certificate(
        expiration: Date?,
        revoked: Bool = false
    ) -> CertificateRecord {
        CertificateRecord(
            id: UUID().uuidString,
            uuid: nil,
            nickname: "Fixture",
            date: nil,
            expiration: expiration,
            isDefault: false,
            ppQCheck: true,
            revoked: revoked,
            profile: nil,
            additionalProfilePatterns: []
        )
    }

    func testValidIdentityIsUsable() {
        XCTAssertTrue(SigningIdentityAvailability.isUsable(certificate(expiration: .distantFuture)))
    }

    func testRevokedIdentityIsNeverUsableEvenWithoutExpiry() {
        let record = certificate(expiration: nil, revoked: true)
        XCTAssertFalse(SigningIdentityAvailability.isUsable(record))
        XCTAssertEqual(SigningIdentityAvailability.installationExpiry(for: record), .distantPast)
    }

    func testExpiredIdentityIsNotUsable() {
        XCTAssertFalse(SigningIdentityAvailability.isUsable(certificate(expiration: .distantPast)))
    }

    func testMissingExpiryIsTreatedAsUnboundedButRevocationStillWins() {
        XCTAssertTrue(SigningIdentityAvailability.isUsable(certificate(expiration: nil)))
        XCTAssertNil(SigningIdentityAvailability.installationExpiry(for: certificate(expiration: nil)))
    }

    func testOnlyRevokedOrExpiredIdentitiesDoNotAdvertiseAnUpdate() {
        let now = Date()
        let revoked = certificate(expiration: now.addingTimeInterval(3600), revoked: true)
        let expired = certificate(expiration: now.addingTimeInterval(-3600))
        XCTAssertFalse(SigningIdentityAvailability.hasUsableIdentity(in: [revoked, expired], at: now))
        XCTAssertTrue(SigningIdentityAvailability.hasUsableIdentity(
            in: [revoked, certificate(expiration: now.addingTimeInterval(3600))], at: now
        ))
    }
}
