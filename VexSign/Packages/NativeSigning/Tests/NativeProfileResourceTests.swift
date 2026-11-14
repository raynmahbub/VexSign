import Foundation
import XCTest
@testable import NativeSigningLinkSmoke

/// Binding policy fixtures only, not certificate/CMS trust or portal validation.
final class NativeProfileResourceTests: XCTestCase {
    private static let now = Date(timeIntervalSince1970: 10_000)
    private static let certificate = Data([1, 2, 3]) // synthetic, NOT X.509
    private static func validation(bundle: String = "com.example.fixture", cert: Data = NativeProfileResourceTests.certificate) throws -> NativeProfileValidationRequest {
        try .init(teamIdentifier: "ABCDE12345", bundleIdentifier: bundle,
                  deviceIdentifier: "0000ABCD-0011223344556677", certificateDER: cert)
    }
    private static func request() throws -> NativeProfileCreationRequest {
        try .init(identityID: UUID(), validation: validation(), appID: "APP1", deviceID: "DEVICE1", certificateID: "CERT1")
    }

    func testOwnedProjectionBindsUUIDCertificateIDAndAllTargetFields() throws {
        let request = try Self.request()
        let owned = NativeOwnedProfileIdentity(identityID: request.identityID, certificateIdentifier: "CERT1", validation: request.validation)
        XCTAssertNoThrow(try NativeProfileResourcePolicy.requireOwned(owned, request: request))
        let wrong: [NativeOwnedProfileIdentity] = [
            .init(identityID: UUID(), certificateIdentifier: "CERT1", validation: request.validation),
            .init(identityID: request.identityID, certificateIdentifier: "OTHER", validation: request.validation),
            .init(identityID: request.identityID, certificateIdentifier: "CERT1", validation: try Self.validation(bundle: "com.example.other")),
            .init(identityID: request.identityID, certificateIdentifier: "CERT1", validation: try Self.validation(cert: Data([4])))
        ]
        for value in wrong { XCTAssertThrowsError(try NativeProfileResourcePolicy.requireOwned(value, request: request)) }
        XCTAssertEqual(owned.description, "NativeOwnedProfileIdentity(redacted)")
    }

    func testExactEnabledDeviceAndAppRegistrationsMatch() throws {
        let device = try NativeRegistrationSubject(kind: .device, value: "0000ABCD-0011223344556677")
        let app = try NativeRegistrationSubject(kind: .appID, value: "com.example.fixture")
        XCTAssertNoThrow(try NativeProfileResourcePolicy.requireRegistration([.init(subject: device, remoteIdentifier: "DEVICE1", enabled: true, expiresAt: nil)],
            subject: device, remoteIdentifier: "DEVICE1", now: Self.now, requireExpiry: false))
        XCTAssertNoThrow(try NativeProfileResourcePolicy.requireRegistration([.init(subject: app, remoteIdentifier: "APP1", enabled: true, expiresAt: Self.now.addingTimeInterval(60))],
            subject: app, remoteIdentifier: "APP1", now: Self.now, requireExpiry: true))
    }

    func testAppLifetimeMissingExpiredOrDisabledCannotAuthorizeProfile() throws {
        let app = try NativeRegistrationSubject(kind: .appID, value: "com.example.fixture")
        for expiry in [nil, Self.now, Self.now.addingTimeInterval(-1)] as [Date?] {
            XCTAssertThrowsError(try NativeProfileResourcePolicy.requireRegistration([.init(subject: app, remoteIdentifier: "APP1", enabled: true, expiresAt: expiry)],
                subject: app, remoteIdentifier: "APP1", now: Self.now, requireExpiry: true))
        }
        XCTAssertThrowsError(try NativeProfileResourcePolicy.requireRegistration([.init(subject: app, remoteIdentifier: "APP1", enabled: false, expiresAt: Self.now.addingTimeInterval(60))],
            subject: app, remoteIdentifier: "APP1", now: Self.now, requireExpiry: true))
    }

    func testRemoteAliasesCaseVariantsAndDuplicateMatchesAreRejected() throws {
        let app = try NativeRegistrationSubject(kind: .appID, value: "com.example.fixture")
        let alias = try NativeRegistrationSubject(kind: .appID, value: "com.example.Fixture")
        let good = NativeRegistrationObservation(subject: app, remoteIdentifier: "APP1", enabled: true, expiresAt: Self.now.addingTimeInterval(60))
        let rows: [[NativeRegistrationObservation]] = [[], [good, good],
            [.init(subject: alias, remoteIdentifier: "APP1", enabled: true, expiresAt: good.expiresAt)],
            [.init(subject: app, remoteIdentifier: "OTHER", enabled: true, expiresAt: good.expiresAt)]]
        for row in rows {
            XCTAssertThrowsError(try NativeProfileResourcePolicy.requireRegistration(row, subject: app, remoteIdentifier: "APP1", now: Self.now, requireExpiry: true))
        }
    }

    func testCertificateRequiresExactOwnedIDAndDER() throws {
        let request = try Self.request()
        let row = NativeProfileCertificateObservation(identifier: "CERT1", certificateDER: Self.certificate)
        XCTAssertNoThrow(try NativeProfileResourcePolicy.requireCertificate([row], request: request))
        for rows in [[], [NativeProfileCertificateObservation(identifier: "OTHER", certificateDER: Self.certificate)],
                     [.init(identifier: "CERT1", certificateDER: Data([4]))], [row, row]] {
            XCTAssertThrowsError(try NativeProfileResourcePolicy.requireCertificate(rows, request: request))
        }
        XCTAssertEqual(row.description, "NativeProfileCertificateObservation(redacted)")
    }

    func testCertificateDERUnderMultipleRemoteIDsIsAmbiguous() throws {
        let rows: [NativeProfileCertificateObservation] = [.init(identifier: "CERT1", certificateDER: Self.certificate),
                                                          .init(identifier: "OTHER", certificateDER: Self.certificate)]
        XCTAssertThrowsError(try NativeProfileResourcePolicy.requireCertificate(rows, request: Self.request()))
    }

    func testOversizeCertificateAndNonFiniteClockAreRejected() throws {
        XCTAssertThrowsError(try NativeProfileResourcePolicy.requireCertificate([.init(identifier: "CERT1", certificateDER: Data(repeating: 0, count: 64 * 1024 + 1))], request: Self.request()))
        let app = try NativeRegistrationSubject(kind: .appID, value: "com.example.fixture")
        XCTAssertThrowsError(try NativeProfileResourcePolicy.requireRegistration([], subject: app, remoteIdentifier: "APP1", now: Date(timeIntervalSince1970: .nan), requireExpiry: true))
    }
}
