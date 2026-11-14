import XCTest
import Security
@testable import VexSign

final class CredentialMigrationDiagnosticsTests: XCTestCase {
    func testClassificationDoesNotDiagnosePermissionsAsCorruptionOrDefiniteLock() {
        XCTAssertEqual(CredentialMigrationIssue.classify(SecureSecretStore.Failure(status: errSecInteractionNotAllowed)), .keychainUnavailable)
        XCTAssertEqual(CredentialMigrationIssue.classify(SecureSecretStore.Failure(status: errSecNotAvailable)), .keychainUnavailable)
        XCTAssertEqual(CredentialMigrationIssue.classify(SecureSecretStore.Failure(status: errSecDecode)), .needsAttention)
        XCTAssertEqual(CredentialMigrationIssue.classify(CocoaError(.fileReadNoPermission)), .accessUnavailable)
        XCTAssertEqual(CredentialMigrationIssue.classify(CocoaError(.fileWriteNoPermission)), .accessUnavailable)
        XCTAssertEqual(CredentialMigrationIssue.classify(CocoaError(.fileWriteOutOfSpace)), .storageFull)
    }

    func testDirectoryFailureReportsWarningAndRetainsOriginalBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) } // try? ok: test teardown only
        let legacy = root.appendingPathComponent("legacy")
        let destination = root.appendingPathComponent("private")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let original = legacy.appendingPathComponent("identity.p12")
        try Data("fixture-bytes".utf8).write(to: original)
        var warnings: [CredentialMigrationIssue?] = []
        let chosen = ProtectedCertificateFiles.directory(legacy: legacy, destination: destination,
            migration: { _, _ in throw CocoaError(.fileWriteOutOfSpace) }, report: { warnings.append($0) })
        XCTAssertEqual(chosen, legacy)
        XCTAssertEqual(warnings, [.storageFull])
        XCTAssertEqual(try Data(contentsOf: original), Data("fixture-bytes".utf8))
        let retried = ProtectedCertificateFiles.directory(legacy: legacy, destination: destination,
                                                         report: { warnings.append($0) })
        XCTAssertEqual(retried, destination)
        XCTAssertEqual(warnings, [.storageFull, nil])
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("identity.p12")), Data("fixture-bytes".utf8))
    }

    func testKeychainReadFailureNeverClearsLegacyOrWritesReplacement() {
        var wrote = false
        var cleared = false
        XCTAssertThrowsError(try CertificatePasswordMigration.resolve(legacy: "fixture-password",
            read: { throw SecureSecretStore.Failure(status: errSecInteractionNotAllowed) },
            write: { _ in wrote = true }, clearLegacy: { cleared = true }))
        XCTAssertFalse(wrote)
        XCTAssertFalse(cleared)
    }

    func testKeychainWriteFailureNeverClearsLegacyPassword() {
        var cleared = false
        XCTAssertThrowsError(try CertificatePasswordMigration.resolve(legacy: "fixture-password",
            read: { nil }, write: { _ in throw SecureSecretStore.Failure(status: errSecNotAvailable) },
            clearLegacy: { cleared = true }))
        XCTAssertFalse(cleared)
    }

    func testSuccessfulMigrationWritesBeforeClearingAndPreservesEmptyPassword() throws {
        var order: [String] = []
        let result = try CertificatePasswordMigration.resolve(legacy: nil, read: { nil },
            write: { data in
                XCTAssertTrue(data.isEmpty)
                order.append("write")
            }, clearLegacy: { order.append("clear") })
        XCTAssertEqual(result, "")
        XCTAssertEqual(order, ["write", "clear"])
    }

    func testExistingKeychainValueWinsWithoutOverwrite() throws {
        var cleared = false
        let result = try CertificatePasswordMigration.resolve(legacy: "old-fixture", read: { Data("secure-fixture".utf8) },
            write: { _ in XCTFail("Must not overwrite secure credentials") }, clearLegacy: { cleared = true })
        XCTAssertEqual(result, "secure-fixture")
        XCTAssertTrue(cleared)
    }

    @MainActor
    func testSuccessOnlyResolvesItsOwnIdentityWarning() {
        let diagnostics = CredentialMigrationDiagnostics()
        diagnostics.update(source: .certificatePassword, id: "first", issue: .keychainUnavailable)
        diagnostics.update(source: .certificatePassword, id: "second", issue: .storageFull)
        diagnostics.update(source: .certificateFiles, id: "managed", issue: .storageFull)
        diagnostics.update(source: .certificatePassword, id: "second", issue: nil)
        XCTAssertEqual(Set(diagnostics.warnings), [.keychainUnavailable, .storageFull])
        diagnostics.update(source: .certificateFiles, id: "managed", issue: nil)
        XCTAssertEqual(diagnostics.warnings, [.keychainUnavailable])
        diagnostics.update(source: .certificatePassword, id: "first", issue: nil)
        XCTAssertTrue(diagnostics.warnings.isEmpty)
    }

    func testWarningsNeverExposeRawErrorDetails() {
        let error = NSError(domain: "sensitive-account", code: 42,
                            userInfo: [NSLocalizedDescriptionKey: "fixture-password /private/identity.p12"])
        let message = CredentialMigrationIssue.classify(error).message
        for secret in ["fixture-password", "/private/identity.p12", "sensitive-account"] {
            XCTAssertFalse(message.contains(secret))
        }
    }
}
