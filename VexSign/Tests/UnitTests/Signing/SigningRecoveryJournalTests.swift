import XCTest
@testable import VexSign

final class SigningRecoveryJournalTests: XCTestCase {
    private enum SimulatedError: Error {
        case storeUnavailable
        case fileLocked
    }

    private func makeSandbox(_ label: String) throws -> (
        root: URL,
        journal: SigningRecoveryJournal,
        tempRoot: URL,
        signedRoot: URL
    ) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        let journalRoot = root.appendingPathComponent("Journal", isDirectory: true)
        let tempRoot = root.appendingPathComponent("Temp", isDirectory: true)
        let signedRoot = root.appendingPathComponent("Signed", isDirectory: true)
        try fm.createDirectory(at: journalRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: signedRoot, withIntermediateDirectories: true)
        addTeardownBlock {
            try? fm.removeItem(at: root)
        }
        return (root, SigningRecoveryJournal(root: journalRoot), tempRoot, signedRoot)
    }

    func testCrashAfterMoveBeforeDatabaseCommitCleansBothTempAndUncommittedSignedDir() throws {
        let fm = FileManager.default
        let (_, journal, tempRoot, signedRoot) = try makeSandbox("SigningRecoveryBeforeCommit")
        let opID = UUID().uuidString
        let workDir = tempRoot.appendingPathComponent("VexSigning_\(opID)", isDirectory: true)
        let uncommittedSignedDir = signedRoot.appendingPathComponent(opID, isDirectory: true)
        let existingSignedDir = signedRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: uncommittedSignedDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: existingSignedDir, withIntermediateDirectories: true)
        try Data("temp".utf8).write(to: workDir.appendingPathComponent("scratch.bin"))
        try Data("uncommitted".utf8).write(to: uncommittedSignedDir.appendingPathComponent("App.app"))
        try Data("unrelated".utf8).write(to: existingSignedDir.appendingPathComponent("Other.app"))

        let record = SigningRecoveryJournal.Record(
            operationID: opID,
            appName: "SampleApp",
            sourceAppUUID: UUID().uuidString,
            workDirectoryName: "VexSigning_\(opID)",
            state: .registering,
            createdWorkDirectory: true,
            createdSignedDirectory: true,
            committedToDatabase: false,
            cleanupAttempts: 0,
            lastError: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
        try journal.save(record)

        let report = journal.reconcile(
            temporaryRoot: tempRoot,
            signedRoot: signedRoot,
            rowExists: { _ in false },
            isOperationActive: { _ in false }
        )

        XCTAssertEqual(report.cleanedWorkDirectories, 1)
        XCTAssertEqual(report.cleanedUncommittedSignedDirectories, 1)
        XCTAssertEqual(report.preservedCommittedSignedDirectories, 0)
        XCTAssertTrue(report.unresolved.isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: workDir.path))
        XCTAssertFalse(fm.fileExists(atPath: uncommittedSignedDir.path))
        XCTAssertTrue(
            fm.fileExists(atPath: existingSignedDir.appendingPathComponent("Other.app").path),
            "Recovery must touch only operation-owned directories."
        )
        XCTAssertTrue(try journal.loadAll().records.isEmpty)
    }

    func testCrashAfterDatabaseCommitPreservesCommittedSignedAppAndCleansTempOnly() throws {
        let fm = FileManager.default
        let (_, journal, tempRoot, signedRoot) = try makeSandbox("SigningRecoveryAfterCommit")
        let opID = UUID().uuidString
        let workDir = tempRoot.appendingPathComponent("VexSigning_\(opID)", isDirectory: true)
        let committedSignedDir = signedRoot.appendingPathComponent(opID, isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: committedSignedDir, withIntermediateDirectories: true)
        try Data("temp".utf8).write(to: workDir.appendingPathComponent("scratch.bin"))
        try Data("committed-app".utf8).write(to: committedSignedDir.appendingPathComponent("Signed.app"))

        // Even if the journal still shows `.registering`, the committed Core Data row wins.
        let record = SigningRecoveryJournal.Record(
            operationID: opID,
            appName: "CommittedApp",
            sourceAppUUID: nil,
            workDirectoryName: "VexSigning_\(opID)",
            state: .registering,
            createdWorkDirectory: true,
            createdSignedDirectory: true,
            committedToDatabase: false,
            cleanupAttempts: 0,
            lastError: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
        try journal.save(record)

        let report = journal.reconcile(
            temporaryRoot: tempRoot,
            signedRoot: signedRoot,
            rowExists: { $0 == opID },
            isOperationActive: { _ in false }
        )

        XCTAssertEqual(report.cleanedWorkDirectories, 1)
        XCTAssertEqual(report.cleanedUncommittedSignedDirectories, 0)
        XCTAssertEqual(report.preservedCommittedSignedDirectories, 1)
        XCTAssertTrue(report.unresolved.isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: workDir.path))
        XCTAssertTrue(
            fm.fileExists(atPath: committedSignedDir.appendingPathComponent("Signed.app").path),
            "Committed signed app must never be deleted during launch reconciliation."
        )
        XCTAssertTrue(try journal.loadAll().records.isEmpty)
    }

    func testActiveOperationAndUnreadableStoreDeferReconciliationSafely() throws {
        let fm = FileManager.default
        let (_, journal, tempRoot, signedRoot) = try makeSandbox("SigningRecoveryDefer")
        let activeID = UUID().uuidString
        let activeSignedDir = signedRoot.appendingPathComponent(activeID, isDirectory: true)
        try fm.createDirectory(at: activeSignedDir, withIntermediateDirectories: true)

        let record = SigningRecoveryJournal.Record(
            operationID: activeID,
            appName: "LiveRun",
            sourceAppUUID: nil,
            workDirectoryName: "VexSigning_\(activeID)",
            state: .signing,
            createdWorkDirectory: true,
            createdSignedDirectory: true,
            committedToDatabase: false,
            cleanupAttempts: 0,
            lastError: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
        try journal.save(record)

        // Active run is skipped.
        let activeReport = journal.reconcile(
            temporaryRoot: tempRoot,
            signedRoot: signedRoot,
            rowExists: { _ in false },
            isOperationActive: { $0 == activeID }
        )
        XCTAssertEqual(activeReport.deferredCount, 1)
        XCTAssertTrue(fm.fileExists(atPath: activeSignedDir.path))

        // Unreadable DB defers without deleting signed output.
        let storeDownReport = journal.reconcile(
            temporaryRoot: tempRoot,
            signedRoot: signedRoot,
            rowExists: { _ in throw SimulatedError.storeUnavailable },
            isOperationActive: { _ in false }
        )
        XCTAssertEqual(storeDownReport.deferredCount, 1)
        XCTAssertEqual(storeDownReport.unresolved.count, 1)
        XCTAssertTrue(fm.fileExists(atPath: activeSignedDir.path))
    }

    func testFailedCleanupAndCorruptRecordsSurfaceInDiagnostics() throws {
        let fm = FileManager.default
        let (_, journal, tempRoot, signedRoot) = try makeSandbox("SigningRecoveryDiagnostics")
        let opID = UUID().uuidString
        let workDir = tempRoot.appendingPathComponent("VexSigning_\(opID)", isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)

        let record = SigningRecoveryJournal.Record(
            operationID: opID,
            appName: "FailingCleanup",
            sourceAppUUID: nil,
            workDirectoryName: "VexSigning_\(opID)",
            state: .failed,
            createdWorkDirectory: true,
            createdSignedDirectory: false,
            committedToDatabase: false,
            cleanupAttempts: 0,
            lastError: "Simulated signing failure",
            createdAt: Date(),
            updatedAt: Date()
        )
        try journal.save(record)
        try Data("{corrupt".utf8).write(to: journal.root.appendingPathComponent("corrupt.json"))

        let report = journal.reconcile(
            temporaryRoot: tempRoot,
            signedRoot: signedRoot,
            rowExists: { _ in false },
            isOperationActive: { _ in false },
            removeDirectory: { _, _ in throw SimulatedError.fileLocked }
        )

        XCTAssertEqual(report.corruptJournalCount, 1)
        XCTAssertEqual(report.unresolved.count, 1)
        XCTAssertEqual(report.unresolved.first?.state, .cleanupPending)
        XCTAssertEqual(report.unresolved.first?.cleanupAttempts, 1)
        XCTAssertEqual(journal.unresolvedRecords().count, 1)
    }
}
