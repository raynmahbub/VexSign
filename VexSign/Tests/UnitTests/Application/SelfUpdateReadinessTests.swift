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

    // No availability/configuration flag can authorize credential egress or
    // turn an unconfirmed paired self replacement into a supported workflow.
    func testConfiguredAndUnconfiguredServersNeverRequestSigningMaterial() {
        for configured in [false, true] {
            let result = plan(.server, server: configured)
            XCTAssertFalse(result.canInstall)
            XCTAssertEqual(result.blocker, .remoteSigningDisabled)
            XCTAssertNil(result.alternative)
        }
    }

    func testNoBlockerOffersConfigurationAsASelfInstallWorkaround() {
        for blocker in [SelfUpdateBlocker.combinedHost, .serverNotConfigured, .pairingMissing,
                        .noDownload, .remoteSigningDisabled, .pairedRouteUnavailable] {
            XCTAssertTrue(blocker.isFinal, "No method picker can enable self replacement in this build")
        }
    }

    func testPairingPresenceDoesNotAuthorizeSelfReplacement() {
        let result = plan(.idevice)
        XCTAssertFalse(result.canInstall)
        XCTAssertEqual(result.blocker, .pairedRouteUnavailable)
        XCTAssertNil(result.alternative)
    }

    func testMissingPairingDoesNotOfferAKeyUploadingServerAsFallback() {
        let result = plan(.idevice, pairing: false)
        XCTAssertEqual(result.blocker, .pairingMissing)
        XCTAssertNil(result.alternative)
    }

    func testMissingReleaseAssetHasNoSilentAlternative() {
        let result = plan(.idevice, download: false)
        XCTAssertEqual(result.blocker, .noDownload)
        XCTAssertNil(result.alternative)
        XCTAssertFalse(plan(.server, download: false).canInstall)
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
		for blocker in [SelfUpdateBlocker.serverNotConfigured, .pairingMissing, .noDownload, .combinedHost, .remoteSigningDisabled, .pairedRouteUnavailable] {
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
		for value in ["", "   ", "ftp://updater.example.com", "https://", "not a url", "https://user:secret@example.com", "https://example.com?token=secret", "https://example.com#fragment"] {
			XCTAssertNil(
				SelfUpdateManager.normalizedServerBaseURL(value),
				"\(value.isEmpty ? "<empty>" : value) cannot serve /vexsign/sign"
			)
		}
	}
}
