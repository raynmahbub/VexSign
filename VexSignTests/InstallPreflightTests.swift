//
//  InstallPreflightTests.swift
//  VexSignTests
//
//  the install-method preflight names the missing prerequisite before the install, instead
//  of letting it fail later with a socket error. The evaluation is pure, so it is tested here.
//

import Foundation
import XCTest
@testable import VexSign

final class InstallPreflightTests: XCTestCase {
	private func readiness(
		_ method: InstallMethodKind,
		cert: Bool = false,
		pairing: Bool = false,
		trollstore: Bool = false
	) -> InstallReadiness {
		InstallPreflight.readiness(
			for: method,
			InstallPreflightInputs(
				hasServerCertificate: cert,
				pairing: pairing ? .readable(udid: "00008120-001A2B3C4D5E6F70") : .absent,
				trollStoreDetected: trollstore
			)
		)
	}

	// MARK: - Every method is reported

	func testReportCoversEveryRouteOnce() {
		let report = InstallPreflight.report(InstallPreflightInputs())
		XCTAssertEqual(report.count, InstallMethodKind.allCases.count)
		XCTAssertEqual(Set(report.map(\.method)), Set(InstallMethodKind.allCases))
		XCTAssertEqual(Set(report.map(\.id)).count, report.count)
	}

	// MARK: - Server

	func testCertificatePresenceDoesNotImplySystemTrust() {
        guard case .missing = readiness(.server, cert: true) else {
            return XCTFail("A profile must be trusted, not merely present")
        }
    }

    func testServerIsReadyOnlyWithConfirmedSystemTrust() {
        let inputs = InstallPreflightInputs(hasServerCertificate: true, hasTrustedServerCertificate: true)
        XCTAssertEqual(InstallPreflight.readiness(for: .server, inputs), .ready)
    }

	func testServerNamesTheMissingCertificate() {
		guard case .missing(let message) = readiness(.server, cert: false) else {
			return XCTFail("expected a missing prerequisite")
		}
		XCTAssertTrue(message.localizedCaseInsensitiveContains("certificate"), message)
	}

	// MARK: - idevice

	func testPairingFilePresenceDoesNotProveDeviceConnectivity() {
		guard case .unknown = readiness(.idevice, pairing: true) else {
			return XCTFail("A file does not prove pairing or VPN connectivity")
		}
	}

	func testIdeviceNamesTheMissingPairingFile() {
		guard case .missing(let message) = readiness(.idevice, pairing: false) else {
			return XCTFail("expected a missing prerequisite")
		}
		XCTAssertTrue(message.localizedCaseInsensitiveContains("pairing"), message)
	}

	func testGuestRequiresProcessLocalRuntime() {
		guard case .unavailable = readiness(.liveContainer) else {
			return XCTFail("A standalone app must not pretend to have an embedded runtime")
		}
		XCTAssertEqual(InstallPreflight.readiness(for: .liveContainer,
			.init(hasEmbeddedRuntime: true)), .ready)
	}

	func testStoredRouteMappingPreservesExistingPreferences() {
		XCTAssertEqual(InstallMethodKind.selected(forStoredValue: 0), .server)
		XCTAssertEqual(InstallMethodKind.selected(forStoredValue: 1), .idevice)
		XCTAssertEqual(InstallMethodKind.selected(forStoredValue: 2), .liveContainer)
		XCTAssertNil(InstallMethodKind.selected(forStoredValue: -1))
		XCTAssertNil(InstallMethodKind.selected(forStoredValue: 99))
	}

	func testPairingImportRejectsInvalidRecords() throws {
		for data in [Data(), Data("not a plist".utf8),
			try PropertyListSerialization.data(fromPropertyList: ["HostID": " "], format: .xml, options: 0),
			try PropertyListSerialization.data(fromPropertyList: ["Unrelated": "value"], format: .binary, options: 0)] {
			XCTAssertThrowsError(try FR.validatePairingFile(data))
		}
		XCTAssertThrowsError(try FR.validatePairingFile(Data(repeating: 0, count: 2 * 1024 * 1024 + 1)))
		let valid = try PropertyListSerialization.data(fromPropertyList: ["HostID": "test-host"], format: .xml, options: 0)
		XCTAssertNoThrow(try FR.validatePairingFile(valid))
	}

	// MARK: - Export

	func testExportNeedsNothing() {
		// No certificate, no pairing file, no TrollStore — still available.
		XCTAssertEqual(readiness(.export), .ready)
	}

	// MARK: - TrollStore

	func testTrollStoreIsUnavailableWhenNotDetected() {
		guard case .unavailable(let message) = readiness(.trollstore) else {
			return XCTFail("expected an unavailable verdict")
		}
		// And it says what VexSign does not do.
		XCTAssertTrue(message.localizedCaseInsensitiveContains("never installs"), message)
	}

	func testTrollStoreIsReadyWhenDetected() {
		XCTAssertEqual(readiness(.trollstore, trollstore: true), .ready)
	}

	func testContainerInventoryFailsClosed() {
		XCTAssertEqual(ContainerGuestState.derive(runtimeAvailable: false, answer: ["state": "imported"]), .unavailable)
		XCTAssertEqual(ContainerGuestState.derive(runtimeAvailable: true, answer: nil), .unknown)
		XCTAssertEqual(ContainerGuestState.derive(runtimeAvailable: true, answer: ["state": "unexpected"]), .unknown)
		XCTAssertEqual(ContainerGuestState.derive(runtimeAvailable: true, answer: ["state": "notImported"]), .notImported)
		XCTAssertEqual(ContainerGuestState.derive(runtimeAvailable: true, answer: ["state": "imported", "version": "2"]), .imported(version: "2"))
	}

	func testImportedGuestDoesNotChangeDeviceEvidence() {
		let request = LibraryStatusStore.Request(uuid: "guest", bundleIdentifier: "test.app",
			expectedVersion: "2", bundleURL: nil, isSigned: false)
		let status = LibraryStatusStore.resolve(request, probe: GuestInventoryDeviceProbe(),
			readSignature: { _ in .unreadable("Unexpected signature read") },
			readGuest: { _ in .imported(version: "2") })
		XCTAssertEqual(status.installed, .unknown)
		XCTAssertEqual(status.guest, .imported(version: "2"))
	}

	// MARK: - Presentation

	func testSummaryIsDistinctPerState() {
		let summaries = [
			InstallPreflight.summary(for: .ready),
			InstallPreflight.summary(for: .missing("x")),
			InstallPreflight.summary(for: .unavailable("x")),
			InstallPreflight.summary(for: .unknown("x"))
		]
		XCTAssertEqual(Set(summaries).count, 4)
	}

	func testDetailExplainsReadyMethodsInsteadOfRepeatingTheSummary() {
		for method in InstallMethodKind.allCases {
			let detail = InstallPreflight.detail(for: InstallMethodReport(method: method, readiness: .ready))
			XCTAssertFalse(detail.isEmpty, "\(method) has no detail")
			XCTAssertNotEqual(detail, InstallPreflight.summary(for: .ready))
		}
	}

	func testDetailPassesThroughTheMissingPrerequisite() {
		let message = "No pairing file."
		let detail = InstallPreflight.detail(
			for: InstallMethodReport(method: .idevice, readiness: .missing(message))
		)
		XCTAssertEqual(detail, message)
	}
}

private struct GuestInventoryDeviceProbe: InstalledAppProbing {
    func installedApp(for bundleIdentifier: String) -> InstalledApp? { nil }
}
