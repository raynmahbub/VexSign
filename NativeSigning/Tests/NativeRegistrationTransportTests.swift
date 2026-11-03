import Foundation
import XCTest
import SideSign
@testable import NativeSigningLinkSmoke

/// Policy/DTO fixtures only. No actual URLSession, Apple response or mutation.
final class NativeRegistrationTransportTests: XCTestCase {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let udid = "0000ABCD-0011223344556677"
    private static func device(_ changes: [String: String] = [:]) throws -> VexSignRegistrationDevice {
        var fields = ["deviceNumber": udid, "deviceId": "DEVICE1", "deviceClass": "iPhone", "status": "Enabled"]
        fields.merge(changes) { _, new in new }
        return try JSONDecoder().decode(VexSignRegistrationDevice.self, from: JSONSerialization.data(withJSONObject: fields))
    }
    private static func app(_ bundle: String, id: String = "APP1", expiry: Date? = Date(timeIntervalSince1970: 1_800_000_600)) throws -> VexSignRegistrationAppID {
        var fields = ["appIdId": id, "identifier": bundle]
        if let expiry { fields["expirationDate"] = ISO8601DateFormatter().string(from: expiry) }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(VexSignRegistrationAppID.self, from: JSONSerialization.data(withJSONObject: fields))
    }
    private static func subject(_ kind: NativeRegistrationSubject.Kind = .appID) throws -> NativeRegistrationSubject {
        try .init(kind: kind, value: kind == .device ? udid : "com.example.fixture")
    }

    func testDeviceRequiresExplicitClassAndStatusRatherThanSDKDefaults() throws {
        for missing in ["deviceClass", "status", "deviceNumber"] {
            var fields = ["deviceClass": "iphone", "status": "enabled", "deviceNumber": Self.udid]
            fields.removeValue(forKey: missing)
            XCTAssertThrowsError(try JSONDecoder().decode(VexSignRegistrationDevice.self, from: JSONSerialization.data(withJSONObject: fields)))
        }
    }

    func testEnabledIOSDeviceIsMappedWithoutGuessingPlatform() throws {
        let result = try SideSignRegistrationInventoryPolicy.observations(.devices([Self.device()]), subject: Self.subject(.device), now: Self.now)
        XCTAssertEqual(result.count, 1); XCTAssertTrue(try XCTUnwrap(result.first).enabled)
        for changes in [["deviceClass": "mac"], ["deviceClass": "unknown"], ["status": "c"], ["status": "disabled"]] {
            let rows = try SideSignRegistrationInventoryPolicy.observations(.devices([Self.device(changes)]), subject: Self.subject(.device), now: Self.now)
            XCTAssertFalse(try XCTUnwrap(rows.first).enabled)
        }
    }

    func testDeviceDuplicateUDIDAndRemoteIDFailClosed() throws {
        let duplicateUDID = try Self.device(["deviceId": "DEVICE2", "deviceNumber": Self.udid.lowercased()])
        XCTAssertThrowsError(try SideSignRegistrationInventoryPolicy.observations(.devices([Self.device(), duplicateUDID]), subject: Self.subject(.device), now: Self.now))
        let duplicateID = try Self.device(["deviceNumber": "11111111-0011223344556677"])
        XCTAssertThrowsError(try SideSignRegistrationInventoryPolicy.observations(.devices([Self.device(), duplicateID]), subject: Self.subject(.device), now: Self.now))
    }

    func testUnrelatedWildcardDoesNotSatisfyExplicitAppID() throws {
        let result = try SideSignRegistrationInventoryPolicy.observations(.appIDs([Self.app("com.example.*")]), subject: Self.subject(), now: Self.now)
        XCTAssertTrue(result.isEmpty)
        let matched = try SideSignRegistrationInventoryPolicy.observations(.appIDs([Self.app("com.example.*"), Self.app("com.example.fixture", id: "APP2")]), subject: Self.subject(), now: Self.now)
        XCTAssertEqual(matched.count, 1); XCTAssertTrue(try XCTUnwrap(matched.first).enabled)
    }

    func testMissingOrExpiredAppIDLifetimeIsNotEnabled() throws {
        for expiry in [nil, Self.now, Self.now.addingTimeInterval(-1)] as [Date?] {
            let rows = try SideSignRegistrationInventoryPolicy.observations(.appIDs([Self.app("com.example.fixture", expiry: expiry)]), subject: Self.subject(), now: Self.now)
            XCTAssertFalse(try XCTUnwrap(rows.first).enabled)
        }
    }

    func testCaseAliasIsPreservedForExecutorToRejectAndDuplicatesFail() throws {
        let rows = try SideSignRegistrationInventoryPolicy.observations(.appIDs([Self.app("com.example.Fixture")]), subject: Self.subject(), now: Self.now)
        XCTAssertNotEqual(try XCTUnwrap(rows.first).subject, try Self.subject())
        XCTAssertThrowsError(try SideSignRegistrationInventoryPolicy.observations(.appIDs([
            Self.app("com.example.fixture"), Self.app("com.example.Fixture", id: "APP2")]), subject: Self.subject(), now: Self.now))
    }

    func testWrongInventoryKindAndMalformedIdentifiersAreRejected() throws {
        XCTAssertThrowsError(try SideSignRegistrationInventoryPolicy.observations(.devices([]), subject: Self.subject(), now: Self.now))
        XCTAssertThrowsError(try SideSignRegistrationInventoryPolicy.observations(.appIDs([Self.app("com.example.fixture", id: "bad/id")]), subject: Self.subject(), now: Self.now))
        XCTAssertThrowsError(try SideSignRegistrationInventoryPolicy.observations(.devices([Self.device(["deviceNumber": "vendor-id"])]), subject: Self.subject(.device), now: Self.now))
    }
}
