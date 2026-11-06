import Foundation
import XCTest
@testable import NativeSigningLinkSmoke

final class NativeAccountProfileOperationTests: XCTestCase {
    private let identity = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private func target(bundle: String = "com.example.fixture", device: String = "0000ABCD-0011223344556677",
                        app: String = "APP1", remoteDevice: String = "DEVICE1", selected: UUID? = nil) throws -> NativeAccountProfileTarget {
        try .init(identityID: identity, bundleIdentifier: bundle, deviceIdentifier: device,
                  registeredAppID: app, registeredDeviceID: remoteDevice, selectedProfileUUID: selected)
    }
    func testTargetDigestBindsExactBundleAndRegisteredIDs() throws {
        let original = try target().approvalDigest
        XCTAssertEqual(original.count, 64)
        XCTAssertNotEqual(original, try target(bundle: "com.example.Fixture").approvalDigest)
        XCTAssertNotEqual(original, try target(app: "APP2").approvalDigest)
        XCTAssertNotEqual(original, try target(remoteDevice: "DEVICE2").approvalDigest)
        XCTAssertNotEqual(original, try target(selected: UUID()).approvalDigest)
        let otherIdentity = try NativeAccountProfileTarget(identityID: UUID(), bundleIdentifier: "com.example.fixture",
            deviceIdentifier: "0000ABCD-0011223344556677", registeredAppID: "APP1", registeredDeviceID: "DEVICE1")
        XCTAssertNotEqual(original, otherIdentity.approvalDigest)
    }
    func testRegistrationResultsSupplyExactRemoteIDsWithoutPublishingThem() throws {
        let app = NativeRegistrationResult(remoteIdentifier: "APP1", operationID: nil)
        let device = NativeRegistrationResult(remoteIdentifier: "DEVICE1", operationID: UUID())
        let typed = try NativeAccountProfileTarget(identityID: identity, bundleIdentifier: "com.example.fixture",
            deviceIdentifier: "0000ABCD-0011223344556677", appRegistration: app, deviceRegistration: device)
        XCTAssertEqual(typed.approvalDigest, try target().approvalDigest)
        XCTAssertFalse(String(describing: app).contains("APP1"))
        XCTAssertFalse(String(describing: device).contains("DEVICE1"))
    }

    func testDeviceCaseNormalizesButBundleCaseDoesNot() throws {
        XCTAssertEqual(try target().approvalDigest, try target(device: "0000abcd-0011223344556677").approvalDigest)
        XCTAssertEqual(try target(device: "0000abcd-0011223344556677").deviceIdentifier, "0000ABCD-0011223344556677")
    }
    func testInvalidTargetsAreRejectedBeforeBackendEntry() {
        XCTAssertThrowsError(try target(bundle: "com.example.*"))
        XCTAssertThrowsError(try target(bundle: "com..example"))
        XCTAssertThrowsError(try target(device: "invalid"))
        XCTAssertThrowsError(try target(app: ""))
        XCTAssertThrowsError(try target(remoteDevice: "bad remote id"))
        XCTAssertThrowsError(try target(app: String(repeating: "A", count: 257)))
    }
    func testTargetDescriptionNeverExposesNamesIDsOrDevice() throws {
        let value = try target()
        XCTAssertEqual(value.description, "NativeAccountProfileTarget(redacted)")
        XCTAssertEqual(value.debugDescription, value.description)
        XCTAssertFalse(String(reflecting: value).contains("com.example"))
        XCTAssertFalse(String(reflecting: value).contains("0011223344556677"))
    }
}
