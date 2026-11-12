import Foundation
import XCTest
import Security
@testable import VexSign

final class CompanionCredentialMigrationTests: XCTestCase {
    private enum Keys {
        static let password = "VexSign.companion.password"
        static let token = "VexSign.companion.token"
    }

    private func defaults() -> (UserDefaults, String) {
        let suite = "CompanionCredentialMigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    func testPasswordAndTokenMigrateToKeychainAndSurviveAStoreRestart() throws {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("legacy-password", forKey: Keys.password)
        defaults.set("legacy-token", forKey: Keys.token)
        var keychain: [String: Data] = [:]

        let password = try SecureSecretStore.migrateDefaults(
            Keys.password,
            account: "companion.password",
            defaults: defaults,
            read: { keychain[$0] },
            write: { keychain[$1] = $0 }
        )
        let token = try SecureSecretStore.migrateDefaults(
            Keys.token,
            account: "companion.apiToken",
            defaults: defaults,
            read: { keychain[$0] },
            write: { keychain[$1] = $0 }
        )

        XCTAssertEqual(password, "legacy-password")
        XCTAssertEqual(token, "legacy-token")
        XCTAssertNil(defaults.string(forKey: Keys.password))
        XCTAssertNil(defaults.string(forKey: Keys.token))
        XCTAssertEqual(String(decoding: try XCTUnwrap(keychain["companion.password"]), as: UTF8.self), password)
        XCTAssertEqual(String(decoding: try XCTUnwrap(keychain["companion.apiToken"]), as: UTF8.self), token)

        // A second process has no defaults to fall back to; the Keychain values
        // alone restore both credentials.
        let relaunchedPassword = try SecureSecretStore.migrateDefaults(
            Keys.password,
            account: "companion.password",
            defaults: defaults,
            read: { keychain[$0] },
            write: { keychain[$1] = $0 }
        )
        let relaunchedToken = try SecureSecretStore.migrateDefaults(
            Keys.token,
            account: "companion.apiToken",
            defaults: defaults,
            read: { keychain[$0] },
            write: { keychain[$1] = $0 }
        )
        XCTAssertEqual(relaunchedPassword, password)
        XCTAssertEqual(relaunchedToken, token)
    }

    func testKeychainReadFailureRetainsLegacyCredentialAndDoesNotWrite() throws {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("legacy-password", forKey: Keys.password)
        var wrote = false

        XCTAssertThrowsError(try SecureSecretStore.migrateDefaults(
            Keys.password,
            account: "companion.password",
            defaults: defaults,
            read: { _ in throw SecureSecretStore.Failure(status: errSecInteractionNotAllowed) },
            write: { _, _ in wrote = true }
        ))

        XCTAssertFalse(wrote)
        XCTAssertEqual(defaults.string(forKey: Keys.password), "legacy-password")
    }

    func testKeychainWriteFailureRetainsLegacyCredential() throws {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("legacy-token", forKey: Keys.token)

        XCTAssertThrowsError(try SecureSecretStore.migrateDefaults(
            Keys.token,
            account: "companion.apiToken",
            defaults: defaults,
            read: { _ in nil },
            write: { _, _ in throw SecureSecretStore.Failure(status: errSecNotAvailable) }
        ))

        XCTAssertEqual(defaults.string(forKey: Keys.token), "legacy-token")
    }

    func testExistingKeychainCredentialWinsAndLegacyCopyIsRemoved() throws {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("stale-legacy", forKey: Keys.password)

        let migrated = try SecureSecretStore.migrateDefaults(
            Keys.password,
            account: "companion.password",
            defaults: defaults,
            read: { _ in Data("secure-value".utf8) },
            write: { _, _ in XCTFail("An existing Keychain credential must not be overwritten") }
        )

        XCTAssertEqual(migrated, "secure-value")
        XCTAssertNil(defaults.string(forKey: Keys.password))
    }

    func testNoLegacyValueDoesNotCreateAnEmptyKeychainItem() throws {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var wrote = false

        let value = try SecureSecretStore.migrateDefaults(
            Keys.token,
            account: "companion.apiToken",
            defaults: defaults,
            read: { _ in nil },
            write: { _, _ in wrote = true }
        )

        XCTAssertEqual(value, "")
        XCTAssertFalse(wrote)
    }
}
