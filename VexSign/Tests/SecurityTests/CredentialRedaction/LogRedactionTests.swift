//
//  LogRedactionTests.swift
//  VexSignTests
//
//  Tests for the log a user can export must not contain their secrets.
//
//  Every rule is asserted in both directions — what it must mask, and what it must leave alone.
//  A redaction rule that over-fires is worse than none: it hides the reason a sign failed.
//

import Foundation
import XCTest
@testable import VexSign

final class LogRedactionTests: XCTestCase {
	private func assertRedacted(
		_ input: String,
		_ secret: String,
		file: StaticString = #filePath,
		line: UInt = #line
	) {
		let output = LogRedaction.redact(input)
		XCTAssertFalse(output.contains(secret), "\(secret) survived redaction: \(output)", file: file, line: line)
		XCTAssertTrue(output.contains(LogRedaction.marker), "nothing was masked in: \(output)", file: file, line: line)
	}

    func testPrivateKeysPairingMaterialAndCookiesAreRedacted() {
        assertRedacted("-----BEGIN RSA PRIVATE KEY-----\nprivate-bytes\n-----END RSA PRIVATE KEY-----", "private-bytes")
        assertRedacted("<key>HostPrivateKey</key>\n<data>pairing-bytes</data>", "pairing-bytes")
        assertRedacted("Cookie: session=private-session; other=private-cookie", "private-session")
        assertRedacted("Set-Cookie: session=private-session", "private-session")
        XCTAssertEqual(LogRedaction.redact("Install failed at verifying"), "Install failed at verifying")
    }

	// MARK: - What must be masked

	func testPasswordAssignmentsAreMasked() {
		assertRedacted("p12Password=hunter2", "hunter2")
		assertRedacted("password: hunter2", "hunter2")
		assertRedacted("password=\"hun ter\"", "hun ter")
	}

	func testTokensAndKeysAreMasked() {
		assertRedacted("token=abc123def456", "abc123def456")
		assertRedacted("api_key=sk-live-1234", "sk-live-1234")
		assertRedacted("X-API-Key: sk-live-1234", "sk-live-1234")
		assertRedacted("secret=topsecret", "topsecret")
	}

	func testBearerTokensAreMasked() {
		assertRedacted("Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.payload.sig", "eyJhbGciOiJIUzI1NiJ9")
		assertRedacted("sent Bearer abcdef123456 upstream", "abcdef123456")
	}

	func testAnAuthorizationSchemeWithoutTheBearerWordIsMaskedToo() {
		assertRedacted("authorization: Basic dXNlcjpwYXNz", "dXNlcjpwYXNz")
	}

	func testPasswordInsideAURLIsMaskedButTheHostSurvives() {
		let output = LogRedaction.redact("fetching https://alice:s3cret@example.com/repo.json")
		XCTAssertFalse(output.contains("s3cret"))
		XCTAssertTrue(output.contains("example.com/repo.json"), "the host is the useful part: \(output)")
	}

    func testLocalDeviceContainerPathsAreMaskedWithoutHidingTheFailureReason() {
        for path in [
            "/private/var/mobile/Containers/Data/Application/fixture/VexSign.sqlite",
            "/var/mobile/Containers/Data/Application/fixture/VexSign.sqlite-wal",
            "file:///private/var/containers/Bundle/Application/fixture/VexSign.app",
            "/var/containers/Bundle/Application/fixture/VexSign.app"
        ] {
            let output = LogRedaction.redact("Failed to open \(path) (SQLite error 11)")
            XCTAssertFalse(output.contains("/var/"), output)
            XCTAssertTrue(output.contains(LogRedaction.marker), output)
            XCTAssertTrue(output.contains("(SQLite error 11)"), output)
            XCTAssertEqual(LogRedaction.redact(output), output)
        }
    }

    func testSimulatorContainerPathsAreMaskedButPublicURLPathsRemainUseful() {
        let path = "file:///Users/fixture/Library/Developer/CoreSimulator/Devices/fixture-device/data/Containers/Data/Application/fixture/VexSign.sqlite"
        let output = LogRedaction.redact("Could not read \"\(path)\": SQLite error 11")
        XCTAssertFalse(output.contains("/Users/fixture"), output)
        XCTAssertTrue(output.contains(LogRedaction.marker), output)
        XCTAssertTrue(output.contains("SQLite error 11"), output)
        XCTAssertEqual(LogRedaction.redact(output), output)
        for url in ["https://example.com/var/mobile/backup.sqlite", "https://example.com/Users/fixture/Library/Developer/CoreSimulator/Devices/help"] {
            XCTAssertEqual(LogRedaction.redact("GET \(url)"), "GET \(url)")
        }
    }

	// MARK: - What must be left alone

	func testAnOrdinaryLogLineIsUntouched() {
		let line = "Signed Example.app (com.example.app) 2.1.0 from https://example.com/repo.json in 4.2s"
		XCTAssertEqual(LogRedaction.redact(line), line)
	}

	/// A word that merely contains one of the keys is not a key.
	func testWordsThatOnlyContainAKeywordAreUntouched() {
		let line = "tokenised the entitlements and re-sealed the bundle"
		XCTAssertEqual(LogRedaction.redact(line), line)
	}

	func testAURLWithoutCredentialsIsUntouched() {
		let line = "GET https://cdn.example.com/app.ipa"
		XCTAssertEqual(LogRedaction.redact(line), line)
	}

	func testEmptyInputStaysEmpty() {
		XCTAssertEqual(LogRedaction.redact(""), "")
	}

	// MARK: - Shape

	func testRedactionIsIdempotent() {
		let once = LogRedaction.redact("password=hunter2 and token=abc123")
		XCTAssertEqual(LogRedaction.redact(once), once)
		let account = LogRedaction.redact("appleID=jane.appleseed@example.com")
		XCTAssertEqual(LogRedaction.redact(account), account)
	}

	// MARK: - Account, pairing and device material

	func testAccountAndPairingJSONKeysAreRedacted() {
		let line = #"{"certificateP12":"MIIKOAIBAzCCCf4","certificatePassword":"not-a-real-password","adiPb":"c2VjcmV0"}"#
		assertRedacted(line, "MIIKOAIBAzCCCf4")
		assertRedacted(line, "not-a-real-password")
		assertRedacted(line, "c2VjcmV0")
	}

    func testRemotePairingHostKeysAndPrettyPrintedByteArraysAreRedacted() {
        for key in ["private_key", "public_key", "alt_irk", "HostPrivateKey"] {
            for value in ["[104, 207, 19]", "Data([\n    104,\n    207,\n    19,\n])"] {
                let output = LogRedaction.redact("\"\(key)\": \(value), transport: failed")
                for byte in ["104", "207", "19"] { XCTAssertFalse(output.contains(byte), output) }
                XCTAssertTrue(output.contains(LogRedaction.marker), output)
                XCTAssertTrue(output.contains("transport: failed"), output)
                XCTAssertEqual(LogRedaction.redact(output), output)
            }
        }
        assertRedacted("<key>public_key</key><data>public-host-material</data>", "public-host-material")
    }

    func testRemoteHostUUIDIsMaskedWithoutHidingBundleIdentifiersOrTaskIDs() {
        let host = "11111111-2222-3333-4444-555555555555"
        for value in ["\"\(host)\"", "String(\"\(host)\")", host] {
            assertRedacted("\"identifier\": \(value)", host)
        }
        for safe in ["identifier=com.example.app", "identifier: example-artifact", "taskID: \(host)"] {
            XCTAssertEqual(LogRedaction.redact(safe), safe)
        }
    }

	func testAppleAccountAndAnisetteHeadersAreRedacted() {
		assertRedacted("X-Apple-I-MD: AAAABBBBCCCCDDDD", "AAAABBBBCCCCDDDD")
		assertRedacted("appleID=jane.appleseed@example.com", "jane.appleseed@example.com")
		assertRedacted(#"{"anisetteAdiBlob":"bWFjaGluZQ=="}"#, "bWFjaGluZQ==")
	}

	func testDeviceIdentifiersAndNamesAreRedacted() {
		assertRedacted("SerialNumber: F2LXK0AAHG7F", "F2LXK0AAHG7F")
		assertRedacted("UDID: 00008120-001E348201E8001E", "00008120-001E348201E8001E")
		assertRedacted("DeviceName = Jane's iPhone", "Jane's iPhone")
		assertRedacted(
			"UniqueDeviceID = 0123456789abcdef0123456789abcdef01234567",
			"0123456789abcdef0123456789abcdef01234567"
		)
	}

	func testEmailAddressesAreMaskedButDomainSurvives() {
		let output = LogRedaction.redact("contact jane.appleseed@example.com for help")
		XCTAssertFalse(output.contains("jane.appleseed"))
		XCTAssertTrue(output.contains("@example.com"), "the domain is useful: \(output)")
		XCTAssertTrue(output.contains(LogRedaction.marker))
	}

	func testBareHashesAreNotMistakenForUDIDs() {
		let line = "commit 0123456789abcdef0123456789abcdef01234567"
		XCTAssertEqual(LogRedaction.redact(line), line)
	}

	/// Several secrets on one line are all masked, not just the first match.
	func testEveryOccurrenceOnALineIsMasked() {
		let output = LogRedaction.redact("first password=one then password=two")
		XCTAssertFalse(output.contains("one "))
		XCTAssertFalse(output.contains("two"))
	}

	func testDiagnosticExporterUsesUnifiedLogRedaction() {
		let raw = """
		UDID: 00008120-001E348201E8001E
		contact jane.appleseed@example.com
		X-VexSign-Token: secret-vex-token-123
		passphrase="cert-passphrase" client_secret=shh_client access_token=tok_abc
		path=/private/var/mobile/Containers/Data/Application/fixture/VexSign.sqlite
		-----BEGIN OPENSSH PRIVATE KEY-----
		ssh-private-material
		-----END OPENSSH PRIVATE KEY-----
		"""
		let sanitized = DiagnosticBundleExporter._sanitize(raw)
		for leaked in [
			"00008120-001E348201E8001E",
			"jane.appleseed",
			"secret-vex-token-123",
			"cert-passphrase",
			"shh_client",
			"tok_abc",
			"/private/var/mobile",
			"ssh-private-material"
		] {
			XCTAssertFalse(sanitized.contains(leaked), "\(leaked) survived diagnostic sanitization: \(sanitized)")
		}
		XCTAssertTrue(sanitized.contains("@example.com"))
	}

	@MainActor
	func testAppLockMigratesLegacyDefaultsIntoVaultAndRequiresAuthToUnlockOrUnhide() {
		let suiteName = "test.applock.\(UUID().uuidString)"
		let defaults = UserDefaults(suiteName: suiteName)!
		addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }

		defaults.set(true, forKey: AppLockManager.enabledKey)
		defaults.set(["app-locked-1"], forKey: "VexSign.security.lockedAppUUIDs")
		defaults.set(["app-hidden-1"], forKey: "VexSign.security.hiddenAppUUIDs")
		defaults.set(true, forKey: AppLockManager.strictHidingKey)

		var storedBlob: Data?
		let storage = AppLockManager.VaultStorage(
			read: { storedBlob },
			write: { storedBlob = $0 }
		)
		var allowAuth = false

		let manager = AppLockManager(
			defaults: defaults,
			storage: storage,
			evaluator: { _, completion in
				completion(allowAuth, nil)
				return true
			}
		)

		// Legacy UserDefaults entries must be migrated to VaultStorage and purged from UserDefaults.
		XCTAssertNotNil(storedBlob)
		XCTAssertNil(defaults.object(forKey: AppLockManager.enabledKey))
		XCTAssertNil(defaults.object(forKey: "VexSign.security.lockedAppUUIDs"))
		XCTAssertNil(defaults.object(forKey: "VexSign.security.hiddenAppUUIDs"))
		XCTAssertNil(defaults.object(forKey: AppLockManager.strictHidingKey))
		XCTAssertTrue(manager.isMasterLockEnabled)
		XCTAssertTrue(manager.isAppLocked("app-locked-1"))
		XCTAssertTrue(manager.isAppHidden("app-hidden-1"))
		XCTAssertTrue(manager.strictHidingEnabled)

		// Failed biometric verification must not disable Master App Lock, unlock an app, unhide an app, or clear strictHiding.
		allowAuth = false
		manager.setMasterLockEnabled(false)
		manager.toggleAppLock("app-locked-1")
		manager.toggleHideApp("app-hidden-1")
		manager.strictHidingEnabled = false
		XCTAssertTrue(manager.isMasterLockEnabled)
		XCTAssertTrue(manager.isAppLocked("app-locked-1"))
		XCTAssertTrue(manager.isAppHidden("app-hidden-1"))
		XCTAssertTrue(manager.strictHidingEnabled)

		// Authenticated verification allows removing locks and unhiding.
		allowAuth = true
		manager.toggleAppLock("app-locked-1")
		manager.toggleHideApp("app-hidden-1")
		manager.strictHidingEnabled = false
		manager.setMasterLockEnabled(false)
		XCTAssertFalse(manager.isAppLocked("app-locked-1"))
		XCTAssertFalse(manager.isAppHidden("app-hidden-1"))
		XCTAssertFalse(manager.strictHidingEnabled)
		XCTAssertFalse(manager.isMasterLockEnabled)
	}

	func testRedirectSanitizationStripsSensitiveHeadersAcrossOriginsAndRejectsDowngrades() throws {
		let source = try XCTUnwrap(URL(string: "https://vexsign-premium.onrender.com/api/validate"))
		let crossHost = try XCTUnwrap(URL(string: "https://cdn.example.net/payload"))
		var request = URLRequest(url: crossHost)
		request.setValue("Bearer secret-jwt", forHTTPHeaderField: "Authorization")
		request.setValue("VEX-KEY-1234", forHTTPHeaderField: "X-API-Key")
		request.setValue("device-uuid-1", forHTTPHeaderField: "vexSignUUID")
		request.setValue("sid=abc", forHTTPHeaderField: "Cookie")

		let sanitized = try XCTUnwrap(VexSignAPI.sanitizedRedirectRequest(from: source, to: request))
		XCTAssertNil(sanitized.value(forHTTPHeaderField: "Authorization"))
		XCTAssertNil(sanitized.value(forHTTPHeaderField: "X-API-Key"))
		XCTAssertNil(sanitized.value(forHTTPHeaderField: "vexSignUUID"))
		XCTAssertNil(sanitized.value(forHTTPHeaderField: "Cookie"))

		let downgrade = URLRequest(url: try XCTUnwrap(URL(string: "http://cdn.example.net/payload")))
		XCTAssertNil(VexSignAPI.sanitizedRedirectRequest(from: source, to: downgrade))
	}
}
