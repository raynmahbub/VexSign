import XCTest
@testable import VexSign

final class AccountRefreshBridgingTests: XCTestCase {
    func testReceiptKeepsTheExactProfileAndExpiry() {
        let profileUUID = UUID()
        let expiry = Date(timeIntervalSince1970: 2_000_000_000)
        let value = AppleAccountProvisioningReceipt(id: UUID(), profileUUID: profileUUID, expiresAt: expiry)
        let mapped = AccountRefreshBridging.receipt(from: value)
        XCTAssertEqual(mapped.profileUUID, profileUUID)
        XCTAssertEqual(mapped.expiresAt, expiry)
    }

    func testHandoffKeepsTheExactIdentity() {
        let app = LibraryAppReference(recordID: "record", uuid: "app-uuid", isSigned: true)
        let profileUUID = UUID()
        let expiry = Date(timeIntervalSince1970: 2_000_000_000)
        let value = AppleAccountSigningHandoff(
            app: app,
            bundleIdentifier: "com.example.app",
            certificateUUID: "certificate-one",
            profileUUID: profileUUID,
            expiresAt: expiry
        )
        let mapped = AccountRefreshBridging.handoff(from: value)
        XCTAssertEqual(mapped.certificateUUID, "certificate-one")
        XCTAssertEqual(mapped.profileUUID, profileUUID)
        XCTAssertEqual(mapped.bundleIdentifier, "com.example.app")
        XCTAssertEqual(mapped.expiresAt, expiry)
    }
}
