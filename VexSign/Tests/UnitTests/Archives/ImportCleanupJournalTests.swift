import XCTest
@testable import VexSign

final class ImportCleanupJournalTests: XCTestCase {
    private enum SimulatedFailure: Error {
        case lockedDirectory
        case databaseUnavailable
    }

    private func makeSandbox(
        _ label: String
    ) throws -> (root: URL, journal: ImportCleanupJournal, temp: URL, unsigned: URL) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        let journalRoot = root.appendingPathComponent("Journal", isDirectory: true)
        let tempRoot = root.appendingPathComponent("Temp", isDirectory: true)
        let unsignedRoot = root.appendingPathComponent("Unsigned", isDirectory: true)
        try fm.createDirectory(at: journalRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: unsignedRoot, withIntermediateDirectories: true)
        addTeardownBlock {
            try? fm.removeItem(at: root)
        }
        return (root, ImportCleanupJournal(root: journalRoot), tempRoot, unsignedRoot)
    }

    func testRecoveryRemovesTempAndUncommittedArtifactWhilePreservingSourceIPA() throws {
        let fm = FileManager.default
        let (root, journal, tempRoot, unsignedRoot) = try makeSandbox("ImportJournalUncommitted")
        let id = UUID().uuidString
        let workDir = tempRoot.appendingPathComponent("VexSignImport_\(id)", isDirectory: true)
        let uncommittedArtifact = unsignedRoot.appendingPathComponent(id, isDirectory: true)
        let sourceIPA = root.appendingPathComponent("Original.ipa")
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: uncommittedArtifact, withIntermediateDirectories: true)
        try Data("temp".utf8).write(to: workDir.appendingPathComponent("copy.ipa"))
        try Data("uncommitted".utf8).write(to: uncommittedArtifact.appendingPathComponent("App.app"))
        try Data("source-ipa".utf8).write(to: sourceIPA)

        let entry = ImportCleanupJournal.Entry(
            id: id,
            fileName: "Original.ipa",
            workDirectoryName: "VexSignImport_\(id)",
            libraryUUID: id,
            state: .moving,
            cleanupAttempts: 0,
            lastCleanupError: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
        try journal.record(entry)

        let report = journal.recoverPending(
            temporaryRoot: tempRoot,
            unsignedRoot: unsignedRoot,
            rowExists: { _ in false },
            isOperationActive: { _ in false }
        )

        XCTAssertEqual(report.cleanedWorkDirectories, 1)
        XCTAssertEqual(report.cleanedUncommittedArtifacts, 1)
        XCTAssertEqual(report.preservedCommittedArtifacts, 0)
        XCTAssertTrue(report.unresolved.isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: workDir.path))
        XCTAssertFalse(fm.fileExists(atPath: uncommittedArtifact.path))
        XCTAssertTrue(fm.fileExists(atPath: sourceIPA.path), "Source IPA must never be deleted by cleanup recovery.")
        XCTAssertTrue(try journal.loadAll().isEmpty)
    }

    func testRecoveryPreservesCommittedLibraryArtifactAndOnlyCleansTempWork() throws {
        let fm = FileManager.default
        let (_, journal, tempRoot, unsignedRoot) = try makeSandbox("ImportJournalCommitted")
        let id = UUID().uuidString
        let workDir = tempRoot.appendingPathComponent("VexSignImport_\(id)", isDirectory: true)
        let committedArtifact = unsignedRoot.appendingPathComponent(id, isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: committedArtifact, withIntermediateDirectories: true)
        try Data("committed-app".utf8).write(to: committedArtifact.appendingPathComponent("Marker.txt"))

        let entry = ImportCleanupJournal.Entry(
            id: id,
            fileName: "Committed.ipa",
            workDirectoryName: "VexSignImport_\(id)",
            libraryUUID: id,
            state: .cleanupPending,
            cleanupAttempts: 1,
            lastCleanupError: "Temporary busy",
            createdAt: Date(),
            updatedAt: Date()
        )
        try journal.record(entry)

        let report = journal.recoverPending(
            temporaryRoot: tempRoot,
            unsignedRoot: unsignedRoot,
            rowExists: { $0 == id },
            isOperationActive: { _ in false }
        )

        XCTAssertEqual(report.cleanedWorkDirectories, 1)
        XCTAssertEqual(report.cleanedUncommittedArtifacts, 0)
        XCTAssertEqual(report.preservedCommittedArtifacts, 1)
        XCTAssertTrue(report.unresolved.isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: workDir.path))
        XCTAssertTrue(fm.fileExists(atPath: committedArtifact.appendingPathComponent("Marker.txt").path))
        XCTAssertTrue(try journal.loadAll().isEmpty)
    }

    func testFailedCleanupPersistsRetryCountAndSucceedsOnNextRecoveryPass() throws {
        let fm = FileManager.default
        let (_, journal, tempRoot, unsignedRoot) = try makeSandbox("ImportJournalRetry")
        let id = UUID().uuidString
        let workDir = tempRoot.appendingPathComponent("VexSignImport_\(id)", isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)

        let entry = ImportCleanupJournal.Entry(
            id: id,
            fileName: "Retry.ipa",
            workDirectoryName: "VexSignImport_\(id)",
            libraryUUID: id,
            state: .failed,
            cleanupAttempts: 0,
            lastCleanupError: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
        try journal.record(entry)

        let first = journal.recoverPending(
            temporaryRoot: tempRoot,
            unsignedRoot: unsignedRoot,
            rowExists: { _ in false },
            isOperationActive: { _ in false },
            removeDirectory: { target, _ in
                if target.lastPathComponent == "VexSignImport_\(id)" {
                    throw SimulatedFailure.lockedDirectory
                }
                return false
            }
        )

        XCTAssertEqual(first.unresolved.count, 1)
        XCTAssertEqual(first.unresolved.first?.state, .cleanupPending)
        XCTAssertEqual(first.unresolved.first?.cleanupAttempts, 1)
        XCTAssertNotNil(first.unresolved.first?.lastCleanupError)
        XCTAssertEqual(journal.unresolvedEntries().count, 1)

        // Second pass succeeds and clears the journal idempotently.
        let second = journal.recoverPending(
            temporaryRoot: tempRoot,
            unsignedRoot: unsignedRoot,
            rowExists: { _ in false },
            isOperationActive: { _ in false }
        )
        XCTAssertTrue(second.unresolved.isEmpty)
        XCTAssertEqual(second.cleanedWorkDirectories, 1)
        XCTAssertTrue(try journal.loadAll().isEmpty)

        // Repeating recovery on an empty journal is a safe no-op.
        let third = journal.recoverPending(
            temporaryRoot: tempRoot,
            unsignedRoot: unsignedRoot,
            rowExists: { _ in false },
            isOperationActive: { _ in false }
        )
        XCTAssertEqual(third, .empty)
    }

    func testUnreadableStoreDefersCleanupWithoutDeletingLibraryArtifacts() throws {
        let fm = FileManager.default
        let (_, journal, tempRoot, unsignedRoot) = try makeSandbox("ImportJournalStoreDown")
        let id = UUID().uuidString
        let artifact = unsignedRoot.appendingPathComponent(id, isDirectory: true)
        try fm.createDirectory(at: artifact, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: artifact.appendingPathComponent("App.app"))

        let entry = ImportCleanupJournal.Entry(
            id: id,
            fileName: "Safe.ipa",
            workDirectoryName: "VexSignImport_\(id)",
            libraryUUID: id,
            state: .registering,
            cleanupAttempts: 0,
            lastCleanupError: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
        try journal.record(entry)

        let report = journal.recoverPending(
            temporaryRoot: tempRoot,
            unsignedRoot: unsignedRoot,
            rowExists: { _ in throw SimulatedFailure.databaseUnavailable },
            isOperationActive: { _ in false }
        )

        XCTAssertEqual(report.deferredActiveOrUnavailable, 1)
        XCTAssertTrue(fm.fileExists(atPath: artifact.appendingPathComponent("App.app").path))
        XCTAssertEqual(try journal.loadAll().count, 1)
    }

    func testAppFileHandlerActorProvidesThreadSafeSnapshotsAndPersistsFailedCopy() async throws {
        let (root, journal, _, _) = try makeSandbox("AppFileHandlerActor")
        let missingIPA = root.appendingPathComponent("DoesNotExist.ipa")

        let handler = AppFileHandler(file: missingIPA, journal: journal)
        let initial = await handler.snapshot()
        XCTAssertEqual(initial.fileName, "DoesNotExist.ipa")
        XCTAssertEqual(initial.lifecycle, .copying)
        XCTAssertFalse(initial.didAddToDatabase)

        do {
            try await handler.copy()
            XCTFail("Expected copy to fail for missing IPA")
        } catch {
            // Expected failure
        }

        let afterFailure = await handler.snapshot()
        XCTAssertEqual(afterFailure.lifecycle, .failed)
        XCTAssertFalse(afterFailure.didAddToDatabase)

        // Cleaning up removes the temporary work directory and clears the journal entry.
        try await handler.clean()
        XCTAssertTrue(try journal.loadAll().isEmpty)
    }
}
