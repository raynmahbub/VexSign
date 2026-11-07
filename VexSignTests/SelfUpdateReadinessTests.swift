//
//  SelfUpdateReadinessTests.swift
//  VexSignTests
//
//  Tapping "Reinstall" used to be allowed in every configuration and then failed with a single
//  sentence that named no cause: the selected method simply was not usable in that build. The plan
//  is pure, so the cases that used to dead-end are pinned here.
//

import Foundation
import XCTest
@testable import VexSign

final class SelfUpdateReadinessTests: XCTestCase {
	private func plan(
		_ preferred: SelfUpdateMethod,
		primaryHost: Bool = false,
		server: Bool = true,
		pairing: Bool = true,
		download: Bool = true
	) -> SelfUpdatePlan {
		SelfUpdateManager.plan(
			preferred: preferred,
			isPrimaryHost: primaryHost,
			serverConfigured: server,
			hasPairing: pairing,
			hasDownload: download
		)
	}

	// MARK: - Server

	func testConfiguredServerInstalls() {
		let result = plan(.server)
		XCTAssertTrue(result.canInstall)
		XCTAssertNil(result.blocker)
		XCTAssertNil(result.alternative)
	}

	func testMissingServerAddressNamesTheBlockerAndOffersIDevice() {
		let result = plan(.server, server: false)
		XCTAssertEqual(result.blocker, .serverNotConfigured)
		XCTAssertEqual(result.alternative, .idevice)
		XCTAssertFalse(result.canInstall)
	}

	func testMissingServerAddressAndNoPairingHasNoWayOut() {
		let result = plan(.server, server: false, pairing: false)
		XCTAssertEqual(result.blocker, .serverNotConfigured)
		XCTAssertNil(result.alternative)
	}

	// MARK: - IDevice

	func testPairedIDeviceInstalls() {
		let result = plan(.idevice)
		XCTAssertTrue(result.canInstall)
		XCTAssertNil(result.blocker)
	}

	func testMissingPairingNamesTheBlockerAndOffersServer() {
		let result = plan(.idevice, pairing: false)
		XCTAssertEqual(result.blocker, .pairingMissing)
		XCTAssertEqual(result.alternative, .server)
	}

	func testReleaseWithoutIPABlocksIDeviceEvenWhenPaired() {
		let result = plan(.idevice, download: false)
		XCTAssertEqual(result.blocker, .noDownload)
		// The server method downloads and signs remotely, so it does not need the asset.
		XCTAssertEqual(result.alternative, .server)
	}

	func testServerPrefersItsOwnMethodWhenTheIPAIsMissing() {
		let result = plan(.server, download: false)
		XCTAssertTrue(result.canInstall)
	}

	// MARK: - Combined host

	func testCombinedHostIsFinalWhateverIsConfigured() {
		let result = plan(.server, primaryHost: true, server: true, pairing: true)
		XCTAssertEqual(result.blocker, .combinedHost)
		XCTAssertTrue(result.blocker?.isFinal == true)
		XCTAssertNil(result.alternative, "No method can replace a combined runtime with a standalone IPA")
	}

	// MARK: - Messages

	func testEveryBlockerExplainsItself() {
		for blocker in [SelfUpdateBlocker.serverNotConfigured, .pairingMissing, .noDownload, .combinedHost] {
			XCTAssertGreaterThan(blocker.message.count, 20, "\(blocker.rawValue) needs a real explanation")
			XCTAssertFalse(blocker.message.contains("isn't available in this build."), "\(blocker.rawValue) must say what to do")
		}
	}

	// MARK: - Server address

	func testSchemeIsAssumedWhenTheUserOmitsIt() {
		XCTAssertEqual(
			SelfUpdateManager.normalizedServerBaseURL("updater.example.com")?.absoluteString,
			"https://updater.example.com"
		)
	}

	func testTrailingSlashAndWhitespaceAreRemoved() {
		XCTAssertEqual(
			SelfUpdateManager.normalizedServerBaseURL("  https://updater.example.com/  ")?.absoluteString,
			"https://updater.example.com"
		)
	}

	func testHostAndPortSurvive() {
		XCTAssertEqual(
			SelfUpdateManager.normalizedServerBaseURL("http://127.0.0.1:8080")?.absoluteString,
			"http://127.0.0.1:8080"
		)
	}

	func testUnusableValuesAreRejected() {
		for value in ["", "   ", "ftp://updater.example.com", "https://", "not a url"] {
			XCTAssertNil(
				SelfUpdateManager.normalizedServerBaseURL(value),
				"\(value.isEmpty ? "<empty>" : value) cannot serve /vexsign/sign"
			)
		}
	}
}
