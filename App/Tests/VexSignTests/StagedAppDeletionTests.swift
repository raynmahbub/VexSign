import CoreData
import XCTest
@testable import VexSign

final class StagedAppDeletionTests: XCTestCase {
    private func fixture() throws -> (URL, URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let original = root.appendingPathComponent("Library/app")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        try Data("original-bytes".utf8).write(to: original.appendingPathComponent("file"))
        return (root, original, root.appendingPathComponent("Quarantine"))
    }
    private let uri = URL(string: "x-coredata://test/Imported/p1")!

    func testRollbackRestoresFilesAfterDatabaseFailure() throws {
        let (root, original, quarantine) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) } // try? ok: test teardown only
        let transaction = try StagedAppDeletion(root: quarantine, originals: [(original, uri)])
        try transaction.stage()
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        let recovered = try StagedAppDeletion(directory: transaction.directory)
        try recovered.recover(rowExists: { _ in true }, allowedOriginal: { $0 == original })
        XCTAssertEqual(try Data(contentsOf: original.appendingPathComponent("file")), Data("original-bytes".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: transaction.directory.path))
    }

    func testPostCommitCleanupFailureRetainsJournalForNextLaunch() throws {
        let (root, original, quarantine) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) } // try? ok: test teardown only
        let transaction = try StagedAppDeletion(root: quarantine, originals: [(original, uri)])
        try transaction.stage()
        XCTAssertThrowsError(try transaction.recover(rowExists: { _ in false }, allowedOriginal: { _ in true },
            remove: { _ in throw CocoaError(.fileWriteNoPermission) }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: transaction.directory.appendingPathComponent("manifest.json").path))
        XCTAssertEqual(try Data(contentsOf: transaction.directory.appendingPathComponent("0/file")), Data("original-bytes".utf8))
        try StagedAppDeletion(directory: transaction.directory).recover(rowExists: { _ in false }, allowedOriginal: { _ in true })
        XCTAssertFalse(FileManager.default.fileExists(atPath: transaction.directory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
    }

    func testUnavailableDatabaseCannotBeTreatedAsDeletedRow() throws {
        let (root, original, quarantine) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) } // try? ok: test teardown only
        let transaction = try StagedAppDeletion(root: quarantine, originals: [(original, uri)])
        try transaction.stage()
        XCTAssertThrowsError(try transaction.recover(rowExists: { _ in throw CocoaError(.fileReadNoPermission) }, allowedOriginal: { _ in true }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: transaction.directory.appendingPathComponent("0/file").path))
    }

    func testPartialStageFailureRestoresOnlyMovedFiles() throws {
        let (root, original, quarantine) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) } // try? ok: test teardown only
        let second = root.appendingPathComponent("Library/second")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let transaction = try StagedAppDeletion(root: quarantine, originals: [(original, uri), (second, uri)])
        XCTAssertThrowsError(try transaction.stage(move: { from, to in
            if from == second { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.moveItem(at: from, to: to)
        }))
        try transaction.recover(rowExists: { _ in true }, allowedOriginal: { _ in true })
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.appendingPathComponent("file").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    func testRecoveryNeverOverwritesANewerOriginal() throws {
        let (root, original, quarantine) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) } // try? ok: test teardown only
        let transaction = try StagedAppDeletion(root: quarantine, originals: [(original, uri)])
        try transaction.stage()
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        try Data("newer".utf8).write(to: original.appendingPathComponent("file"))
        XCTAssertThrowsError(try transaction.recover(rowExists: { _ in true }, allowedOriginal: { _ in true }))
        XCTAssertEqual(try Data(contentsOf: original.appendingPathComponent("file")), Data("newer".utf8))
        XCTAssertEqual(try Data(contentsOf: transaction.directory.appendingPathComponent("0/file")), Data("original-bytes".utf8))
    }

    @MainActor
    func testStorageSaveFailureKeepsRowsFilesAndUnrelatedEdits() throws {
        let storage = Storage(inMemory: true)
        let row = Imported(context: storage.context)
        row.uuid = UUID().uuidString
        row.name = "Target"
        let unrelated = Imported(context: storage.context)
        unrelated.uuid = UUID().uuidString
        unrelated.name = "Before"
        try storage.context.save()
        unrelated.name = "Unsaved edit"
        let directory = try XCTUnwrap(storage.getUuidDirectory(for: row))
        defer { try? FileManager.default.removeItem(at: directory) } // try? ok: test fixture cleanup only
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("retained".utf8).write(to: directory.appendingPathComponent("file"))
        var saveAttempted = false
        XCTAssertFalse(storage.deleteApps([row], saveDeletion: { context in
            saveAttempted = true
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
            XCTAssertEqual(context.deletedObjects.count, 1)
            throw CocoaError(.fileWriteOutOfSpace)
        }))
        XCTAssertTrue(saveAttempted)
        XCTAssertFalse(row.isDeleted)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("file")), Data("retained".utf8))
        XCTAssertEqual(unrelated.name, "Unsaved edit")
        XCTAssertTrue(storage.context.hasChanges)
    }

    @MainActor
    func testSuccessfulDeletionDoesNotSaveUnrelatedEdits() throws {
        let storage = Storage(inMemory: true)
        let row = Imported(context: storage.context)
        row.uuid = UUID().uuidString
        let unrelated = Imported(context: storage.context)
        unrelated.uuid = UUID().uuidString
        unrelated.name = "Before"
        try storage.context.save()
        let unrelatedID = unrelated.objectID
        unrelated.name = "Unsaved"
        let directory = try XCTUnwrap(storage.getUuidDirectory(for: row))
        defer { try? FileManager.default.removeItem(at: directory) } // try? ok: test fixture cleanup only
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertTrue(storage.deleteApps([row]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let reader = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        reader.persistentStoreCoordinator = storage.container.persistentStoreCoordinator
        let stored = try XCTUnwrap(try reader.existingObject(with: unrelatedID) as? Imported)
        XCTAssertEqual(stored.name, "Before")
        XCTAssertEqual(unrelated.name, "Unsaved")
    }
}
