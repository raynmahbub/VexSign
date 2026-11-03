import Foundation
import XCTest
@testable import NativeSigningLinkSmoke

/// Written during coding; execution is deferred to the user's testing phase.
final class NativeProvisioningPlanTests: XCTestCase {
    private let udid = String(repeating: "A", count: 40)
    private let now = Date(timeIntervalSince1970: 10_000)

    func testExplicitLegacyAndModernDeviceIdentifiers() throws {
        let request = try NativeAccountProvisioningRequest(deviceIdentifier: udid, bundleIdentifiers: ["com.example.app"])
        XCTAssertFalse(String(describing: request).contains(udid))
        XCTAssertFalse(String(reflecting: request).contains(udid))
        _ = try NativeAccountProvisioningRequest(deviceIdentifier: "00008101-1234567890ABCDEF", bundleIdentifiers: ["com.example.app"])
    }

    func testMalformedDeviceIdentifiersAreRejectedWithoutNormalization() {
        for identifier in ["", "vendor-id", udid + "\n", " " + udid, String(repeating: "G", count: 40)] {
            XCTAssertThrowsError(try NativeAccountProvisioningRequest(deviceIdentifier: identifier, bundleIdentifiers: ["com.example.app"]))
        }
    }

    func testBundleGraphRejectsWildcardsDuplicatesAndInvalidLabels() {
        for identifiers in [[], ["com.*"], ["com..app"], ["com.example.app", "COM.EXAMPLE.APP"], ["com.example.app\n"], ["single"]] {
            XCTAssertThrowsError(try NativeAccountProvisioningRequest(deviceIdentifier: udid, bundleIdentifiers: identifiers))
        }
    }

    func testReadOnlyPlanNeverTreatsRemoteCertificateAsOwnedPrivateKey() throws {
        let request = try NativeAccountProvisioningRequest(deviceIdentifier: udid, bundleIdentifiers: ["com.example.second", "com.example.first"])
        let inventory = SideSignProvisioningInventory(deviceRegistered: true, appIdentifiers: ["com.example.first"], certificateCount: 2)
        let context = UUID()
        let plan = try inventory.plan(request: request, contextID: context, teamIdentifier: "TEAM", now: now, sessionExpiry: now.addingTimeInterval(600))
        XCTAssertEqual(plan.contextID, context)
        XCTAssertFalse(plan.requiresDeviceRegistration)
        XCTAssertEqual(plan.appIDsToRegister, ["com.example.second"])
        XCTAssertEqual(plan.existingAppIdentifiers, ["com.example.first"])
        XCTAssertEqual(plan.remoteCertificateCount, 2)
        XCTAssertTrue(plan.requiresLocallyOwnedSigningIdentity)
        XCTAssertEqual(plan.profileBundleIdentifiersToPrepare, ["com.example.first", "com.example.second"])
        XCTAssertEqual(plan.expiresAt, now.addingTimeInterval(120))
    }

    func testPlanDeadlineCannotOutliveSession() throws {
        let request = try NativeAccountProvisioningRequest(deviceIdentifier: udid, bundleIdentifiers: ["com.example.app"])
        let inventory = SideSignProvisioningInventory(deviceRegistered: false, appIdentifiers: [], certificateCount: 0)
        let expiry = now.addingTimeInterval(5)
        let plan = try inventory.plan(request: request, contextID: UUID(), teamIdentifier: "TEAM", now: now, sessionExpiry: expiry)
        XCTAssertEqual(plan.expiresAt, expiry)
        XCTAssertTrue(plan.requiresDeviceRegistration)
        let appDeadline = now.addingTimeInterval(2)
        let expiringApp = SideSignProvisioningInventory(deviceRegistered: true, appIdentifiers: ["com.example.app"], certificateCount: 1, validUntil: appDeadline)
        let shortPlan = try expiringApp.plan(request: request, contextID: UUID(), teamIdentifier: "TEAM", now: now, sessionExpiry: expiry)
        XCTAssertEqual(shortPlan.expiresAt, appDeadline)
        XCTAssertThrowsError(try inventory.plan(request: request, contextID: UUID(), teamIdentifier: "TEAM", now: expiry, sessionExpiry: expiry))
    }
}
