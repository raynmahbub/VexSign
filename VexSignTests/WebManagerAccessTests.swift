//
//  WebManagerAccessTests.swift
//  VexSignTests
//
//  Covers the Web Manager access rules: which endpoints
//  require credentials, how the token is compared, when the server is allowed to
//  listen on the network, and the one-time switch to authenticated-by-default.
//
//  Pure policy only - no server is started, so these run on any host.
//

import XCTest
@testable import VexSign

final class WebManagerAccessTests: XCTestCase {

	// MARK: - Sensitive routes

	func testCertificateAndSigningRoutesAreGuarded() {
		let guarded = [
			"/api/certs",
			"/api/certs/",
			"/api/certs/1B4F-2C/download",
			"/api/certs/1B4F-2C",
			"/api/sign"
		]

		for path in guarded {
			XCTAssertTrue(
				WebManagerAccessPolicy.requiresSensitiveAccess(path: path, isDestructive: false),
				"\(path) exposes signing identity and must be guarded"
			)
		}
	}

	func testOrdinaryTransferRoutesStayOpenToTheServerWidePolicy() {
		let open = [
			"/",
			"/upload/app.ipa",
			"/download/app.ipa",
			"/api/files",
			"/api/apps",
			"/api/apps/1234/download",
			"/api/tweaks",
			"/api/status",
			"/api/library",
			"/api/updates",
			"/api/compression"
		]

		for path in open {
			XCTAssertFalse(
				WebManagerAccessPolicy.requiresSensitiveAccess(path: path, isDestructive: false),
				"\(path) is part of normal file transfer and keeps the global policy"
			)
		}
	}

	func testEveryAPIDeleteIsGuarded() {
		let deletes = ["/api/files/a.ipa", "/api/apps/1234", "/api/tweaks/5678", "/api/certs/1234"]

		for path in deletes {
			XCTAssertTrue(
				WebManagerAccessPolicy.requiresSensitiveAccess(path: path, isDestructive: true),
				"DELETE \(path) can destroy user data"
			)
		}

		// The same paths read-only are only sensitive where they carry certificates.
		XCTAssertFalse(WebManagerAccessPolicy.requiresSensitiveAccess(path: "/api/files/a.ipa", isDestructive: false))
		XCTAssertFalse(WebManagerAccessPolicy.requiresSensitiveAccess(path: "/api/apps/1234", isDestructive: false))
	}

	func testPathNormalisationCannotBeUsedToSpellAroundTheGuard() {
		let spellings = [
			"/API/CERTS",
			"//api//certs",
			"/api/certs/",
			"/api/%63erts"
		]

		for path in spellings {
			XCTAssertTrue(
				WebManagerAccessPolicy.requiresSensitiveAccess(path: path, isDestructive: false),
				"\(path) must classify as a certificate route"
			)
		}
	}

	// MARK: - Token

	func testTokenAbsentMeansNoTokenConfigured() {
		XCTAssertTrue(WebManagerAccessPolicy.tokenMatches(expected: nil, provided: nil))
		XCTAssertTrue(WebManagerAccessPolicy.tokenMatches(expected: "", provided: nil))
		XCTAssertTrue(WebManagerAccessPolicy.tokenMatches(expected: "   ", provided: nil))
		XCTAssertTrue(WebManagerAccessPolicy.tokenMatches(expected: nil, provided: "anything"))
	}

	func testTokenComparison() {
		XCTAssertTrue(WebManagerAccessPolicy.tokenMatches(expected: "abc123", provided: "abc123"))
		XCTAssertTrue(WebManagerAccessPolicy.tokenMatches(expected: "abc123\n", provided: "abc123"))
		XCTAssertFalse(WebManagerAccessPolicy.tokenMatches(expected: "abc123", provided: nil))
		XCTAssertFalse(WebManagerAccessPolicy.tokenMatches(expected: "abc123", provided: "abc124"))
		XCTAssertFalse(WebManagerAccessPolicy.tokenMatches(expected: "abc123", provided: "abc1234"))
		XCTAssertFalse(WebManagerAccessPolicy.tokenMatches(expected: "abc123", provided: ""))
	}

	// MARK: - Exposure

	func testUnauthenticatedServerCannotReachTheNetworkByAccident() {
		// Requested LAN, no password, no explicit opt-in: downgraded to loopback.
		XCTAssertEqual(
			WebManagerAccessPolicy.effectiveBindMode(
				requested: .localNetwork, authActive: false, allowUnauthenticatedLAN: false
			),
			.thisDevice
		)

		// Same, but the user explicitly accepted the risk.
		XCTAssertEqual(
			WebManagerAccessPolicy.effectiveBindMode(
				requested: .localNetwork, authActive: false, allowUnauthenticatedLAN: true
			),
			.localNetwork
		)

		// A password makes LAN the user's plain choice.
		XCTAssertEqual(
			WebManagerAccessPolicy.effectiveBindMode(
				requested: .localNetwork, authActive: true, allowUnauthenticatedLAN: false
			),
			.localNetwork
		)

		// Loopback stays loopback whatever else is set.
		XCTAssertEqual(
			WebManagerAccessPolicy.effectiveBindMode(
				requested: .thisDevice, authActive: true, allowUnauthenticatedLAN: true
			),
			.thisDevice
		)
	}

	func testBindHosts() {
		XCTAssertEqual(WebManagerAccessPolicy.bindHost(.thisDevice), "127.0.0.1")
		XCTAssertEqual(WebManagerAccessPolicy.bindHost(.localNetwork), "0.0.0.0")
		XCTAssertEqual(WebManagerBindMode.thisDevice.hostname, "127.0.0.1")
		XCTAssertEqual(WebManagerBindMode.localNetwork.hostname, "0.0.0.0")
	}

	// MARK: - Migration

	private func _temporaryDefaults() -> UserDefaults {
		let name = "test.webmanager.\(UUID().uuidString)"
		let defaults = UserDefaults(suiteName: name)!
		addTeardownBlock { defaults.removePersistentDomain(forName: name) }
		return defaults
	}

	func testFreshInstallDefaultsToAuthenticationWithoutAnExplanation() {
		let defaults = _temporaryDefaults()
		XCTAssertNil(defaults.object(forKey: WebManagerSettingsMigration.Key.auth))

		// Nothing to explain: this install never ran an open server.
		XCTAssertFalse(WebManagerSettingsMigration.migrateAuthDefaultIfNeeded(defaults: defaults))
		XCTAssertTrue(defaults.bool(forKey: WebManagerSettingsMigration.Key.auth))
		XCTAssertTrue(defaults.bool(forKey: WebManagerSettingsMigration.Key.authMigrated))
	}

	func testInstallThatRanOpenIsSwitchedOnAndExplainedOnce() {
		let defaults = _temporaryDefaults()
		defaults.set(false, forKey: WebManagerSettingsMigration.Key.auth)

		XCTAssertTrue(
			WebManagerSettingsMigration.migrateAuthDefaultIfNeeded(defaults: defaults),
			"an install that had auth off must be told why it changed"
		)
		XCTAssertTrue(defaults.bool(forKey: WebManagerSettingsMigration.Key.auth))

		// The migration never runs twice.
		XCTAssertFalse(WebManagerSettingsMigration.migrateAuthDefaultIfNeeded(defaults: defaults))
	}

	func testInstallThatAlreadyRequiredAPasswordIsLeftAlone() {
		let defaults = _temporaryDefaults()
		defaults.set(true, forKey: WebManagerSettingsMigration.Key.auth)

		XCTAssertFalse(WebManagerSettingsMigration.migrateAuthDefaultIfNeeded(defaults: defaults))
		XCTAssertTrue(defaults.bool(forKey: WebManagerSettingsMigration.Key.auth))
	}

	func testUsersWhoTurnAuthenticationOffAgainAreNotRelocked() {
		let defaults = _temporaryDefaults()
		XCTAssertFalse(WebManagerSettingsMigration.migrateAuthDefaultIfNeeded(defaults: defaults))

		// The user deliberately turns it off later.
		defaults.set(false, forKey: WebManagerSettingsMigration.Key.auth)

		XCTAssertFalse(
			WebManagerSettingsMigration.migrateAuthDefaultIfNeeded(defaults: defaults),
			"the migration must not fight a deliberate choice"
		)
		XCTAssertFalse(defaults.bool(forKey: WebManagerSettingsMigration.Key.auth))
	}
}
