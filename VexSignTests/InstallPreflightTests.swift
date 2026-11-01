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
				hasPairingFile: pairing,
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

	func testServerIsReadyWithACertificate() {
		XCTAssertEqual(readiness(.server, cert: true), .ready)
	}

	func testServerNamesTheMissingCertificate() {
		guard case .missing(let message) = readiness(.server, cert: false) else {
			return XCTFail("expected a missing prerequisite")
		}
		XCTAssertTrue(message.localizedCaseInsensitiveContains("certificate"), message)
	}

	// MARK: - idevice

	func testIdeviceIsReadyWithAPairingFile() {
		XCTAssertEqual(readiness(.idevice, pairing: true), .ready)
	}

	func testIdeviceNamesTheMissingPairingFile() {
		guard case .missing(let message) = readiness(.idevice, pairing: false) else {
			return XCTFail("expected a missing prerequisite")
		}
		XCTAssertTrue(message.localizedCaseInsensitiveContains("pairing"), message)
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
