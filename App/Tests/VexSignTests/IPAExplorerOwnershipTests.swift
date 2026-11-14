import CoreData
import XCTest
@testable import VexSign

@MainActor
final class IPAExplorerOwnershipTests: XCTestCase {
    private func fixture() throws -> (Storage, Imported, IPAWorkspace) {
        let storage = Storage(inMemory: true)
        let row = Imported(context: storage.context)
        row.uuid = UUID().uuidString
        row.name = "Editor ownership fixture"
        try storage.context.save()
        let container = try XCTUnwrap(storage.getUuidDirectory(for: row))
        try FileManager.default.createDirectory(at: container.appendingPathComponent("Fixture.app"), withIntermediateDirectories: true)
        return (storage, row, try IPAWorkspace.open(app: row))
    }

    func testBusyLibraryCopyRejectsEveryFileActionWithoutMutation() throws {
        let (storage, row, workspace) = try fixture()
        defer { try? FileManager.default.removeItem(at: workspace.containerURL) } // try? ok: test teardown only
        let file = workspace.appURL.appendingPathComponent("original.txt")
        try Data("original".utf8).write(to: file)
        let replacement = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: replacement) } // try? ok: test teardown only
        try Data("replacement".utf8).write(to: replacement)
        let entry = IPAFileEntry(url: file, name: "original.txt", isDirectory: false,
                                 size: 8, date: Date(), kind: .text, childCount: 0)
        let lease = try AppOperationRegistry.shared.acquire(AppOperationRegistry.key(row))
        defer { withExtendedLifetime((storage, lease)) {} }
        XCTAssertThrowsError(try workspace.acquireEditingLease())
        XCTAssertNil(IPAExplorerActions.createFolder(named: "blocked", in: workspace.appURL, workspace: workspace))
        XCTAssertNil(IPAExplorerActions.rename(entry, to: "renamed.txt", workspace: workspace))
        XCTAssertFalse(IPAExplorerActions.replace(entry, with: replacement, workspace: workspace))
        XCTAssertEqual(IPAExplorerActions.importFiles([replacement], into: workspace.appURL, workspace: workspace), 0)
        IPAExplorerActions.delete(entry, workspace: workspace)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "original")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: workspace.appURL.path), ["original.txt"])
        XCTAssertEqual(workspace.changeCount, 0)
    }

    func testFailedReplacementCopyKeepsOriginalLibraryFile() throws {
        let (storage, _, workspace) = try fixture()
        defer { withExtendedLifetime(storage) {} }
        defer { try? FileManager.default.removeItem(at: workspace.containerURL) }
        let file = workspace.appURL.appendingPathComponent("original.txt")
        try Data("original".utf8).write(to: file)
        let missingSource = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let entry = IPAFileEntry(url: file, name: file.lastPathComponent, isDirectory: false,
                                 size: 8, date: Date(), kind: .text, childCount: 0)

        XCTAssertFalse(IPAExplorerActions.replace(entry, with: missingSource, workspace: workspace))
        XCTAssertEqual(try Data(contentsOf: file), Data("original".utf8))
        XCTAssertEqual(workspace.changeCount, 0)
    }

    func testEditingLeaseBlocksLibraryDeletionAndReleasesAfterScope() throws {
        let (storage, row, workspace) = try fixture()
        defer { try? FileManager.default.removeItem(at: workspace.containerURL) } // try? ok: test teardown only
        do {
            let lease = try workspace.acquireEditingLease()
            defer { withExtendedLifetime(lease) {} }
            XCTAssertFalse(storage.deleteApps([row]))
            XCTAssertFalse(row.isDeleted)
            XCTAssertThrowsError(try AppOperationRegistry.shared.acquire(AppOperationRegistry.key(row)))
        }
        XCTAssertFalse(AppOperationRegistry.shared.isBusy(AppOperationRegistry.key(row)))
        XCTAssertNotNil(IPAExplorerActions.createFolder(named: "allowed", in: workspace.appURL, workspace: workspace))
        XCTAssertEqual(workspace.changeCount, 1)
    }

    func testDeletedWorkspaceCannotRecreateLibraryFilesOrLeakLease() throws {
        let (storage, row, workspace) = try fixture()
        defer { withExtendedLifetime(storage) {} }
        try FileManager.default.removeItem(at: workspace.containerURL)
        XCTAssertThrowsError(try workspace.acquireEditingLease())
        XCTAssertNil(IPAExplorerActions.createFolder(named: "blocked", in: workspace.appURL, workspace: workspace))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.containerURL.path))
        XCTAssertFalse(AppOperationRegistry.shared.isBusy(AppOperationRegistry.key(row)))
    }

    private func archiveWorkspace(blockUndoStorage: Bool) throws -> IPAWorkspace {
        let record = IPAWorkspaceRecord(
            id: UUID().uuidString,
            name: "Undo backup fixture",
            date: Date(),
            isLibraryApp: false
        )
        let workspaceDirectory = record.url
        let appDirectory = workspaceDirectory
            .appendingPathComponent("Extracted", isDirectory: true)
            .appendingPathComponent("Payload", isDirectory: true)
            .appendingPathComponent("Fixture.app", isDirectory: true)
        try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        let metadata = try JSONSerialization.data(withJSONObject: [
            "fileName": "Fixture.ipa",
            "date": Date().timeIntervalSince1970
        ])
        try metadata.write(to: workspaceDirectory.appendingPathComponent(".workspace.json"))
        let backups = workspaceDirectory.appendingPathComponent("Backups", isDirectory: true)
        if blockUndoStorage {
            // A file at the Backups path makes every durable undo-copy attempt fail.
            try Data("not a directory".utf8).write(to: backups)
        } else {
            try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        }
        return try IPAWorkspace.open(recent: record)
    }

    func testArchiveEditsAbortWhenUndoBackupCannotBeCreated() throws {
        let workspace = try archiveWorkspace(blockUndoStorage: true)
        let journal = try XCTUnwrap(workspace.journal)
        defer { try? FileManager.default.removeItem(at: journal.root) }
        let file = workspace.appURL.appendingPathComponent("original.txt")
        try Data("original".utf8).write(to: file)
        let replacement = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: replacement) }
        try Data("replacement".utf8).write(to: replacement)
        let entry = IPAFileEntry(url: file, name: file.lastPathComponent, isDirectory: false,
                                 size: 8, date: Date(), kind: .text, childCount: 0)

        IPAExplorerActions.delete(entry, workspace: workspace)
        XCTAssertFalse(IPAExplorerActions.replace(entry, with: replacement, workspace: workspace))
        XCTAssertThrowsError(try IPAExplorerActions.save(data: Data("replacement".utf8), to: file, workspace: workspace))
        XCTAssertNil(IPAExplorerActions.rename(entry, to: "renamed.txt", workspace: workspace))

        XCTAssertEqual(try Data(contentsOf: file), Data("original".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.deletingLastPathComponent().appendingPathComponent("renamed.txt").path))
        XCTAssertEqual(workspace.changeCount, 0)
        XCTAssertTrue(workspace.journal?.changes.isEmpty == true)
    }

    func testAddedJournalEntriesPersistWithNullBackupName() throws {
        let workspace = try archiveWorkspace(blockUndoStorage: false)
        let journal = try XCTUnwrap(workspace.journal)
        defer { try? FileManager.default.removeItem(at: journal.root) }
        let addedFile = workspace.appURL.appendingPathComponent("added.txt")
        try Data("new".utf8).write(to: addedFile)
        workspace.journalChange(kind: .added, url: addedFile, backupName: nil)

        let record = IPAWorkspaceRecord(id: workspace.id, name: "Undo backup fixture", date: Date(), isLibraryApp: false)
        let reopened = try IPAWorkspace.open(recent: record)
        let restoredChange = try XCTUnwrap(reopened.journal?.changes.first)
        XCTAssertEqual(restoredChange.kind, .added)
        XCTAssertNil(restoredChange.backupName)
    }

    func testEditorSaveRecordsUndoAndRestoresOriginalBytes() throws {
        let workspace = try archiveWorkspace(blockUndoStorage: false)
        let journal = try XCTUnwrap(workspace.journal)
        defer { try? FileManager.default.removeItem(at: journal.root) }
        let file = workspace.appURL.appendingPathComponent("settings.txt")
        try Data("before".utf8).write(to: file)

        try IPAExplorerActions.save(data: Data("after".utf8), to: file, workspace: workspace)
        XCTAssertEqual(try Data(contentsOf: file), Data("after".utf8))
        XCTAssertEqual(workspace.journal?.changes.first?.kind, .modified)
        XCTAssertTrue(workspace.undoChange(at: file))
        XCTAssertEqual(try Data(contentsOf: file), Data("before".utf8))
        XCTAssertTrue(workspace.journal?.changes.isEmpty == true)
    }

    func testImportBatchDoesNotReacquireItsOwnLease() throws {
        let (storage, _, workspace) = try fixture()
        defer { withExtendedLifetime(storage) {} }
        defer { try? FileManager.default.removeItem(at: workspace.containerURL) } // try? ok: test teardown only
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: source) } // try? ok: test teardown only
        try Data("imported".utf8).write(to: source)
        XCTAssertEqual(IPAExplorerActions.importFiles([source], into: workspace.appURL, workspace: workspace), 1)
        XCTAssertEqual(try Data(contentsOf: workspace.appURL.appendingPathComponent(source.lastPathComponent)), Data("imported".utf8))
    }
}
