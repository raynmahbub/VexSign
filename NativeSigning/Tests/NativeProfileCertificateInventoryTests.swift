import Foundation
import XCTest
import SideSign
@testable import NativeSigningLinkSmoke

/// DTO/bounds fixtures. No real HTTP, certificate trust or actual Apple inventory.
final class NativeProfileCertificateInventoryTests: XCTestCase {
    private static func row(id: String = "CERT1", data: Data = Data([1, 2, 3])) throws -> VexSignDevelopmentCertificate {
        try JSONDecoder().decode(VexSignDevelopmentCertificate.self, from: JSONSerialization.data(withJSONObject:
            ["certificateId": id, "certContent": data.base64EncodedString()]))
    }

    func testRequiredActualCertificateIDIsNotRequestIDFallback() throws {
        let fields = ["certRequestId": "REQUEST1", "certContent": Data([1]).base64EncodedString()]
        XCTAssertThrowsError(try JSONDecoder().decode(VexSignDevelopmentCertificate.self, from: JSONSerialization.data(withJSONObject: fields)))
    }

    func testMissingOrMalformedContentCannotBeDroppedAsEmptyInventory() throws {
        for fields in [["certificateId": "CERT1"], ["certificateId": "CERT1", "certContent": "not base64!"]] {
            XCTAssertThrowsError(try JSONDecoder().decode(VexSignDevelopmentCertificate.self, from: JSONSerialization.data(withJSONObject: fields)))
        }
    }

    func testExactBytesAreTransferredWithoutTrustClaim() throws {
        let rows = try NativeProfileCertificateInventoryPolicy.observations([Self.row()])
        XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows.first?.identifier, "CERT1")
        XCTAssertEqual(rows.first?.certificateDER, Data([1, 2, 3]))
        XCTAssertEqual(rows.first?.description, "NativeProfileCertificateObservation(redacted)")
        // Synthetic bytes are not X.509; this stage deliberately is not trust validation.
    }

    func testDuplicateIDsAndDERAreRejectedRatherThanCompacted() throws {
        XCTAssertThrowsError(try NativeProfileCertificateInventoryPolicy.observations([Self.row(), Self.row(data: Data([4]))]))
        XCTAssertThrowsError(try NativeProfileCertificateInventoryPolicy.observations([Self.row(), Self.row(id: "CERT2")]))
    }

    func testInvalidIDEmptyAndOversizedMaterialFailClosed() throws {
        for row in [try Self.row(id: "bad/id"), try Self.row(data: Data()), try Self.row(data: Data(repeating: 0, count: 64 * 1024 + 1))] {
            XCTAssertThrowsError(try NativeProfileCertificateInventoryPolicy.observations([row]))
        }
    }

    func testAggregateAndCountCapsAreIndependent() throws {
        let many = try (0..<9).map { index in try Self.row(id: "CERT\(index)", data: Data(repeating: UInt8(index), count: 64 * 1024)) }
        XCTAssertThrowsError(try NativeProfileCertificateInventoryPolicy.observations(many))
        let overCount = try (0..<1001).map { index in try Self.row(id: "CERT\(index)", data: Data(String(index).utf8)) }
        XCTAssertThrowsError(try NativeProfileCertificateInventoryPolicy.observations(overCount))
    }

    func testExplicitEmptyDecodedInventoryDoesNotInventACertificate() throws {
        XCTAssertTrue(try NativeProfileCertificateInventoryPolicy.observations([]).isEmpty)
        let validation = try NativeProfileValidationRequest(teamIdentifier: "ABCDE12345", bundleIdentifier: "com.example.fixture",
            deviceIdentifier: "0000ABCD-0011223344556677", certificateDER: Data([1]))
        let request = try NativeProfileCreationRequest(identityID: UUID(), validation: validation, appID: "APP1", deviceID: "DEVICE1", certificateID: "CERT1")
        XCTAssertThrowsError(try NativeProfileResourcePolicy.requireCertificate([], request: request))
    }
}
