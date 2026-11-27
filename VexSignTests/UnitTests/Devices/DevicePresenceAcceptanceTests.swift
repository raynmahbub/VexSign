//
//  DevicePresenceAcceptanceTests.swift
//  VexSignTests
//
//  Connection state is evidence, not optimism. These tests use controlled
//  values only; no pairing file, UDID, Apple account or device is involved.
//

import XCTest
import IDeviceSwift
@testable import VexSign

final class DevicePresenceAcceptanceTests: XCTestCase {
    private func context(
        pairing: DevicePairingState = .validated(format: .lockdown, deviceIdentifier: "UDID-FIXTURE"),
        presence: DevicePresence = .connected,
        trust: DeviceTrust = .verified,
        transport: Bool = true,
        inventory: Bool = true
    ) -> DeviceCapabilityContext {
        DeviceCapabilityContext(
            pairing: pairing,
            presence: presence,
            trust: trust,
            pairingTransportAvailable: transport,
            companionAvailable: false,
            osVersion: .init(major: 18, minor: 0),
            inventoryBridgeAvailable: inventory,
            onDeviceHostAvailable: false
        )
    }

    func testOnlyAConfirmedConnectionIsUsable() {
        for state in [DevicePresence.disconnected, .discovering, .discovered, .connecting,
                      .pairingRequired, .unauthorized, .unsupported, .reconnecting,
                      .failed("fixture failure")] {
            XCTAssertFalse(state.isUsable, "\(state.title) must not be treated as a live connection")
        }
        XCTAssertTrue(DevicePresence.connected.isUsable)
    }

    func testConnectedPresenceWithoutTrustCannotAuthorizeInstallation() {
        let report = DeviceCapabilityResolver.report(context(trust: .unverified))
        XCTAssertNotEqual(report.status(for: .pairedInstall), .supported)
    }

    func testConnectedPresenceWithoutSessionTransportCannotAuthorizeInstallation() {
        let report = DeviceCapabilityResolver.report(context(transport: false))
        XCTAssertNotEqual(report.status(for: .pairedInstall), .supported)
    }

    func testCompleteEvidenceStillRequiresInventoryBridge() {
        let report = DeviceCapabilityResolver.report(context(inventory: false))
        XCTAssertNotEqual(report.status(for: .pairedInstall), .supported)
        XCTAssertNotEqual(report.status(for: .inventoryRead), .supported)
    }

    func testCompleteEvidenceReportsSupportedInstallation() {
        let report = DeviceCapabilityResolver.report(context())
        XCTAssertEqual(report.status(for: .pairedInstall), .supported)
        XCTAssertEqual(report.status(for: .inventoryRead), .supported)
    }
}
