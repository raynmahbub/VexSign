import XCTest
@testable import VexSign

final class CertificateDeletionJournalTests: XCTestCase {
    private enum SimulatedError: Error {
        case keychainLocked
        case filesystemBusy
        case storeUnreadable
    }

    private func makeSandbox(_ label: String) throws -> (root: URL, journal: CertificateDeletionJournal) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        let journalRoot = root.appendingPathComponent("Journal", isDirectory: true)
        try fm.createDirectory(at: journalRoot, withIntermediateDirectories: true)
        addTeardownBlock {
            try? fm.removeItem(at: root)
        }
        return (root, CertificateDeletionJournal(root: journalRoot))
    }

    func testKeychainDeletionFailureRetriesUntilKeychainBecomesAvailable() throws {
        let (_, journal) = try makeSandbox("CertJournalKeychainRetry")
        let uuid = UUID().uuidString
        let account = "certificate.password.\(uuid)"
        let entry = CertificateDeletionJournal.Entry(
            uuid: uuid,
            keychainAccount: account,
            directoryPath: nil,
            pendingKeychainDeletion: true,
            pendingFilesystemDeletion: false,
            attempts: 1,
            lastError: "Keychain locked",
            createdAt: Date(),
            updatedAt: Date()
        )
        try journal.record(entry)
        XCTAssertTrue(try journal.hasPendingEntry(forUUID: uuid))

        // First retry: Keychain still locked.
        let lockedReport = journal.recoverPending(
            identityExists: { _ in false },
            deleteSecret: { _ in throw SimulatedError.keychainLocked }
        )
        XCTAssertEqual(lockedReport.resolvedCount, 0)
        XCTAssertEqual(lockedReport.unresolved.count, 1)
        XCTAssertEqual(lockedReport.unresolved.first?.attempts, 2)
        XCTAssertTrue(lockedReport.unresolved.first?.pendingKeychainDeletion == true)

        // Second retry: Keychain unlocked; orphan credential deleted and journal cleared.
        var deletedAccounts: [String] = []
        let unlockedReport = journal.recoverPending(
            identityExists: { _ in false },
            deleteSecret: { deletedAccounts.append($0) }
        )
        XCTAssertEqual(deletedAccounts, [account])
        XCTAssertEqual(unlockedReport.resolvedCount, 1)
        XCTAssertTrue(unlockedReport.unresolved.isEmpty)
        XCTAssertFalse(try journal.hasPendingEntry(forUUID: uuid))
    }

    func testPartialCleanupProgressPersistsRemainingPendingWork() throws {
        let fm = FileManager.default
        let (root, journal) = try makeSandbox("CertJournalPartial")
        let uuid = UUID().uuidString
        let certDir = root.appendingPathComponent(uuid, isDirectory: true)
        try fm.createDirectory(at: certDir, withIntermediateDirectories: true)
        try Data("p12-secret".utf8).write(to: certDir.appendingPathComponent("cert.p12"))

        let entry = CertificateDeletionJournal.Entry(
            uuid: uuid,
            keychainAccount: "certificate.password.\(uuid)",
            directoryPath: certDir.path,
            pendingKeychainDeletion: true,
            pendingFilesystemDeletion: true,
            attempts: 1,
            lastError: "Initial post-commit failure",
            createdAt: Date(),
            updatedAt: Date()
        )
        try journal.record(entry)

        // Keychain succeeds, filesystem still busy.
        var keychainDeleted = false
        let partialReport = journal.recoverPending(
            identityExists: { _ in false },
            deleteSecret: { _ in keychainDeleted = true },
            allowedDirectory: { $0.standardizedFileURL == certDir.standardizedFileURL },
            removeDirectory: { _ in throw SimulatedError.filesystemBusy }
        )

        XCTAssertTrue(keychainDeleted)
        XCTAssertEqual(partialReport.resolvedCount, 0)
        XCTAssertEqual(partialReport.unresolved.count, 1)
        let remaining = try XCTUnwrap(partialReport.unresolved.first)
        XCTAssertFalse(remaining.pendingKeychainDeletion)
        XCTAssertTrue(remaining.pendingFilesystemDeletion)
        XCTAssertEqual(remaining.attempts, 2)

        // Second pass finishes filesystem removal without touching Keychain again.
        var secondKeychainCalls = 0
        let finalReport = journal.recoverPending(
            identityExists: { _ in false },
            deleteSecret: { _ in secondKeychainCalls += 1 },
            allowedDirectory: { $0.standardizedFileURL == certDir.standardizedFileURL },
            removeDirectory: { try fm.removeItem(at: $0) }
        )

        XCTAssertEqual(secondKeychainCalls, 0)
        XCTAssertEqual(finalReport.resolvedCount, 1)
        XCTAssertTrue(finalReport.unresolved.isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: certDir.path))
    }

    func testRecoveryNeverDeletesLiveIdentityOrWhenStoreIsUnreadable() throws {
        let fm = FileManager.default
        let (root, journal) = try makeSandbox("CertJournalGuard")
        let uuid = UUID().uuidString
        let certDir = root.appendingPathComponent(uuid, isDirectory: true)
        try fm.createDirectory(at: certDir, withIntermediateDirectories: true)

        let entry = CertificateDeletionJournal.Entry(
            uuid: uuid,
            keychainAccount: "certificate.password.\(uuid)",
            directoryPath: certDir.path,
            pendingKeychainDeletion: true,
            pendingFilesystemDeletion: true,
            attempts: 1,
            lastError: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
        try journal.record(entry)

        var deletedSecret = false
        var deletedDirectory = false

        let liveReport = journal.recoverPending(
            identityExists: { _ in true },
            deleteSecret: { _ in deletedSecret = true },
            allowedDirectory: { _ in true },
            removeDirectory: { _ in deletedDirectory = true }
        )
        XCTAssertEqual(liveReport.deferredCount, 1)
        XCTAssertFalse(deletedSecret)
        XCTAssertFalse(deletedDirectory)

        let unreadableReport = journal.recoverPending(
            identityExists: { _ in throw SimulatedError.storeUnreadable },
            deleteSecret: { _ in deletedSecret = true },
            allowedDirectory: { _ in true },
            removeDirectory: { _ in deletedDirectory = true }
        )
        XCTAssertEqual(unreadableReport.deferredCount, 1)
        XCTAssertFalse(deletedSecret)
        XCTAssertFalse(deletedDirectory)
    }

    @MainActor
    func testDeletedCertificateCannotBeSelectedAndUUIDReuseIsBlockedWhileCleanupIsPending() throws {
        let storage = Storage(inMemory: true)
        let uuid = UUID().uuidString
        let exp = expectation(description: "addCertificate")
        var addError: Error?
        storage.addCertificate(
            uuid: uuid,
            password: "secret",
            nickname: "TempCert",
            expiration: Date().addingTimeInterval(3600)
        ) { error in
            addError = error
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
        XCTAssertNil(addError)

        let cert = try XCTUnwrap(storage.getAllCertificates().first { $0.uuid == uuid })
        XCTAssertTrue(storage.deleteCertificate(for: cert))
        XCTAssertNil(
            storage.getAllCertificates().first { $0.uuid == uuid },
            "Deleted certificate must immediately disappear from selectable certificates."
        )

        // Simulate a lingering unresolved cleanup entry for the same UUID.
        let pending = CertificateDeletionJournal.Entry(
            uuid: uuid,
            keychainAccount: "certificate.password.\(uuid)",
            directoryPath: nil,
            pendingKeychainDeletion: true,
            pendingFilesystemDeletion: false,
            attempts: 1,
            lastError: "Simulated locked keychain",
            createdAt: Date(),
            updatedAt: Date()
        )
        try CertificateDeletionJournal.defaultJournal.record(pending)
        addTeardownBlock {
            try? CertificateDeletionJournal.defaultJournal.remove(uuid: uuid)
        }

        let reuseExp = expectation(description: "reuseRejected")
        var reuseError: Error?
        storage.addCertificate(
            uuid: uuid,
            password: "new-password",
            nickname: "CollidingCert",
            expiration: Date().addingTimeInterval(3600)
        ) { error in
            reuseError = error
            reuseExp.fulfill()
        }
        wait(for: [reuseExp], timeout: 5)
        XCTAssertNotNil(
            reuseError,
            "Reusing a certificate UUID while an orphaned deletion entry is still pending must be refused."
        )
    }
}
