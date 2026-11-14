import XCTest
import Security
import CoreData
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

    func testCorruptSecurePasswordDoesNotOverwriteOrClearRecoverableLegacyText() {
        var wrote = false, cleared = false
        XCTAssertThrowsError(try CertificatePasswordMigration.resolve(legacy: "recoverable synthetic password",
            read: { Data([0xff, 0xfe]) }, write: { _ in wrote = true }, clearLegacy: { cleared = true }))
        XCTAssertFalse(wrote)
        XCTAssertFalse(cleared)
    }

    func testFailedLegacyClearCanRetryFromTheSecureCopyWithoutWritingItAgain() throws {
        var secure: Data?, writes = 0, clears = 0
        XCTAssertThrowsError(try CertificatePasswordMigration.resolve(legacy: "synthetic migration password",
            read: { secure }, write: { secure = $0; writes += 1 }, clearLegacy: {
                clears += 1; throw CocoaError(.fileWriteOutOfSpace)
            }))
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(clears, 1)
        let result = try CertificatePasswordMigration.resolve(legacy: "synthetic migration password", read: { secure },
            write: { _ in XCTFail("Retry must use the existing secure copy") }, clearLegacy: { clears += 1 })
        XCTAssertEqual(result, "synthetic migration password")
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(clears, 2)
    }

    @MainActor
    private func legacyCertificate(in storage: Storage) throws -> CertificatePair {
        let row = CertificatePair(context: storage.context)
        row.uuid = UUID().uuidString; row.nickname = "Synthetic legacy identity"
        row.password = "synthetic legacy password"; row.date = Date(); row.expiration = .distantFuture
        row.revoked = false; row.ppQCheck = false; row.isDefault = false
        try storage.context.save()
        return row
    }

    @MainActor
    func testInvalidAndDeletedRowsCannotReadOrRecreateAKeychainPassword() throws {
        let storage = Storage(inMemory: true), row = try legacyCertificate(in: storage)
        let originalUUID = row.uuid
        row.uuid = "../invalid-identity"
        XCTAssertThrowsError(try row.requireSigningPassword(readSecret: { _ in
            XCTFail("Invalid UUID must refuse before Keychain access"); return nil
        }, writeSecret: { _, _ in XCTFail("Invalid UUID must not recreate a password") }))
        XCTAssertThrowsError(try row.setSigningPassword("synthetic value"))
        row.uuid = originalUUID
        storage.context.delete(row)
        XCTAssertThrowsError(try row.requireSigningPassword(readSecret: { _ in
            XCTFail("Deleted identity must refuse before Keychain access"); return nil
        }, writeSecret: { _, _ in XCTFail("Deleted identity must not recreate a password") }))
        XCTAssertThrowsError(try row.setSigningPassword("synthetic value"))
    }

    @MainActor
    func testLegacyPasswordMigrationDoesNotCommitUnrelatedOrSameRowPendingEdits() throws {
        let storage = Storage(inMemory: true), row = try legacyCertificate(in: storage)
        let unrelated = Imported(context: storage.context)
        unrelated.uuid = UUID().uuidString; unrelated.name = "Before"
        try storage.context.save()
        unrelated.name = "Pending"; row.nickname = "Pending nickname"
        var secure: Data?
        XCTAssertEqual(try row.requireSigningPassword(readSecret: { _ in secure }, writeSecret: { data, _ in secure = data }),
            "synthetic legacy password")
        XCTAssertNil(row.password)
        XCTAssertEqual(row.nickname, "Pending nickname")
        XCTAssertEqual(unrelated.name, "Pending")
        let reader = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        reader.persistentStoreCoordinator = storage.container.persistentStoreCoordinator
        let persistedRow = try XCTUnwrap(try reader.existingObject(with: row.objectID) as? CertificatePair)
        XCTAssertNil(persistedRow.password)
        XCTAssertEqual(persistedRow.nickname, "Synthetic legacy identity")
        XCTAssertEqual((try reader.existingObject(with: unrelated.objectID) as? Imported)?.name, "Before")
    }

    @MainActor
    func testFailedIsolatedLegacySaveRetainsPlaintextAndAllowsASecureReadRetry() throws {
        let storage = Storage(inMemory: true), row = try legacyCertificate(in: storage)
        var secure: Data?, writes = 0
        XCTAssertThrowsError(try row.requireSigningPassword(readSecret: { _ in secure }, writeSecret: { data, _ in
            secure = data; writes += 1
        }, saveMigration: { _ in throw CocoaError(.fileWriteOutOfSpace) }))
        XCTAssertEqual(row.password, "synthetic legacy password")
        let reader = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        reader.persistentStoreCoordinator = storage.container.persistentStoreCoordinator
        XCTAssertEqual((try reader.existingObject(with: row.objectID) as? CertificatePair)?.password, "synthetic legacy password")
        XCTAssertEqual(try row.requireSigningPassword(readSecret: { _ in secure }, writeSecret: { _, _ in
            XCTFail("Retry must not overwrite the stored secure password")
        }), "synthetic legacy password")
        XCTAssertNil(row.password)
        XCTAssertEqual(writes, 1)
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
