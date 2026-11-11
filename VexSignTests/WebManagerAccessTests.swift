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

final class WebManagerUploadDurabilityTests: XCTestCase {
    private func fixture(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    func testInterruptedUploadPreservesExistingFileAndRemovesPartial() throws {
        try fixture { root in
            let destination = root.appendingPathComponent("existing.ipa")
            try Data([1, 2, 3]).write(to: destination)
            let upload = try WebManagerUploadFile(destination: destination)
            try upload.write(Data([4, 5]))
            upload.abort()
            upload.abort() // Duplicate drain callbacks must not delete the destination.
            XCTAssertEqual(try Data(contentsOf: destination), Data([1, 2, 3]))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["existing.ipa"])
        }
    }

    func testFailedCommitKeepsOriginalAndRemovesPartial() throws {
        try fixture { root in
            let destination = root.appendingPathComponent("existing.ipa")
            try Data([1]).write(to: destination)
            let upload = try WebManagerUploadFile(destination: destination, replace: { _, _ in
                throw CocoaError(.fileWriteNoPermission)
            })
            try upload.write(Data([2]))
            XCTAssertThrowsError(try upload.commit())
            upload.abort()
            XCTAssertEqual(try Data(contentsOf: destination), Data([1]))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["existing.ipa"])
        }
    }

    func testSuccessfulCommitReplacesOriginalOnlyAfterWritingCompletes() throws {
        try fixture { root in
            let destination = root.appendingPathComponent("existing.ipa")
            try Data([1]).write(to: destination)
            let upload = try WebManagerUploadFile(destination: destination)
            try upload.write(Data([2, 3]))
            XCTAssertEqual(try Data(contentsOf: destination), Data([1]))
            try upload.commit()
            upload.abort()
            XCTAssertEqual(try Data(contentsOf: destination), Data([2, 3]))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["existing.ipa"])
        }
    }

    func testRoutingNeverDeletesInboxOriginalOrUnrelatedDirectory() throws {
        try fixture { root in
            let original = root.appendingPathComponent("uploaded.ipa")
            try Data([7]).write(to: original)
            WebManagerRouter.finish(original, stagedDirectory: nil)
            WebManagerRouter.finish(original, stagedDirectory: root.appendingPathComponent("unrelated"))
            XCTAssertEqual(try Data(contentsOf: original), Data([7]))
            let staged = root.appendingPathComponent("staged", isDirectory: true)
            try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
            let copy = staged.appendingPathComponent("uploaded.ipa")
            try Data([7]).write(to: copy)
            WebManagerRouter.finish(copy, stagedDirectory: staged)
            XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
            XCTAssertEqual(try Data(contentsOf: original), Data([7]))
        }
    }
}

final class WebDAVFileTransactionTests: XCTestCase {
    private func fixture(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    func testFailedCopyOrPublishPreservesSourceAndDestination() throws {
        try fixture { root in
            let source = root.appendingPathComponent("source"), destination = root.appendingPathComponent("destination")
            try Data([1]).write(to: source)
            try Data([2]).write(to: destination)
            XCTAssertThrowsError(try WebManagerFileTransaction.transfer(source, to: destination, move: false, copy: { _, temporary in
                try Data([9]).write(to: temporary)
                throw CocoaError(.fileReadUnknown)
            }))
            XCTAssertThrowsError(try WebManagerFileTransaction.transfer(source, to: destination, move: false, publish: { _, _ in
                throw CocoaError(.fileWriteNoPermission)
            }))
            XCTAssertEqual(try Data(contentsOf: source), Data([1]))
            XCTAssertEqual(try Data(contentsOf: destination), Data([2]))
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), Set(["source", "destination"]))
        }
    }

    func testMoveAndCopyReplaceFileOnlyOnSuccess() throws {
        try fixture { root in
            let source = root.appendingPathComponent("source"), destination = root.appendingPathComponent("destination")
            try Data([1]).write(to: source)
            try Data([2]).write(to: destination)
            try WebManagerFileTransaction.transfer(source, to: destination, move: false)
            XCTAssertEqual(try Data(contentsOf: source), Data([1]))
            XCTAssertEqual(try Data(contentsOf: destination), Data([1]))
            try Data([3]).write(to: source)
            try WebManagerFileTransaction.transfer(source, to: destination, move: true)
            XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
            XCTAssertEqual(try Data(contentsOf: destination), Data([3]))
        }
    }

    func testSamePathAndNonemptyDirectoryReplacementFailWithoutDeletion() throws {
        try fixture { root in
            let source = root.appendingPathComponent("source", isDirectory: true)
            let destination = root.appendingPathComponent("destination", isDirectory: true)
            for url in [source, destination] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
            try Data([1]).write(to: source.appendingPathComponent("file"))
            try Data([2]).write(to: destination.appendingPathComponent("file"))
            XCTAssertThrowsError(try WebManagerFileTransaction.transfer(source, to: source, move: true))
            XCTAssertThrowsError(try WebManagerFileTransaction.transfer(source, to: destination, move: true))
            XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("file")), Data([1]))
            XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("file")), Data([2]))
        }
    }
}
