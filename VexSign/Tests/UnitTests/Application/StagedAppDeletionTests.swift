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

    func testUndoCanRestageAfterFailedInsertionWithoutLosingItsJournal() throws {
        let (root, original, quarantine) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) } // try? ok: synthetic test teardown
        let transaction = try StagedAppDeletion(root: quarantine, originals: [(original, uri)])
        try transaction.stage()
        try transaction.recover(rowExists: { _ in true }, allowedOriginal: { $0 == original }, retainingManifest: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.appendingPathComponent("file").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: transaction.directory.appendingPathComponent("manifest.json").path))
        // The database insert failed. The same offer owns the re-staged bytes.
        try transaction.stage()
        let recovered = try StagedAppDeletion(directory: transaction.directory)
        try recovered.recover(rowExists: { _ in false }, allowedOriginal: { $0 == original })
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: transaction.directory.path))
    }

    func testInterruptedUndoPurgesUnownedRestoredBytesBeforeDroppingManifest() throws {
        let (root, original, quarantine) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) } // try? ok: synthetic test teardown
        let transaction = try StagedAppDeletion(root: quarantine, originals: [(original, uri)])
        try transaction.stage()
        try transaction.recover(rowExists: { _ in true }, allowedOriginal: { $0 == original }, retainingManifest: true)
        // A restart occurred before the row insertion. The retained manifest
        // owns the original even though its numbered holding slot is empty.
        let recovered = try StagedAppDeletion(directory: transaction.directory)
        try recovered.recover(rowExists: { _ in false }, allowedOriginal: { $0 == original }, removingUnownedOriginals: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: transaction.directory.path))
    }

    func testFailedRestageStillTracksOriginalAndFailedErasureKeepsJournal() throws {
        let (root, original, quarantine) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) } // try? ok: synthetic test teardown
        let transaction = try StagedAppDeletion(root: quarantine, originals: [(original, uri)])
        try transaction.stage()
        try transaction.recover(rowExists: { _ in true }, allowedOriginal: { $0 == original }, retainingManifest: true)
        XCTAssertThrowsError(try transaction.stage(move: { _, _ in throw CocoaError(.fileWriteNoPermission) }))
        XCTAssertThrowsError(try transaction.recover(rowExists: { _ in false }, allowedOriginal: { $0 == original },
            removingUnownedOriginals: true, remove: { _ in throw CocoaError(.fileWriteNoPermission) }))
        XCTAssertEqual(try Data(contentsOf: original.appendingPathComponent("file")), Data("original-bytes".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: transaction.directory.appendingPathComponent("manifest.json").path))
        try StagedAppDeletion(directory: transaction.directory).recover(rowExists: { _ in false },
            allowedOriginal: { $0 == original }, removingUnownedOriginals: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
    }

    func testUnavailableOwnerReadRetainsRestoredOriginalAndManifest() throws {
        let (root, original, quarantine) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) } // try? ok: synthetic test teardown
        let transaction = try StagedAppDeletion(root: quarantine, originals: [(original, uri)])
        try transaction.stage()
        try transaction.recover(rowExists: { _ in true }, allowedOriginal: { $0 == original }, retainingManifest: true)
        XCTAssertThrowsError(try transaction.recover(rowExists: { _ in throw CocoaError(.fileReadNoPermission) },
            allowedOriginal: { $0 == original }, removingUnownedOriginals: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.appendingPathComponent("file").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: transaction.directory.appendingPathComponent("manifest.json").path))
    }

    func testReplacementOwnerKeepsRestoredOriginalDuringCertificateCleanup() throws {
        let (root, original, quarantine) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) } // try? ok: synthetic test teardown
        let transaction = try StagedAppDeletion(root: quarantine, originals: [(original, uri)])
        try transaction.stage()
        try transaction.recover(rowExists: { _ in true }, allowedOriginal: { $0 == original }, retainingManifest: true)
        try transaction.recover(rowExists: { _ in true }, allowedOriginal: { $0 == original }, removingUnownedOriginals: true)
        XCTAssertEqual(try Data(contentsOf: original.appendingPathComponent("file")), Data("original-bytes".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: transaction.directory.path))
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
        try Data("removable app bytes".utf8).write(to: directory.appendingPathComponent("app"))
        let deletion = storage.deleteAppsWithOutcome([row])
        XCTAssertTrue(deletion.committed)
        XCTAssertGreaterThan(deletion.freedBytes, 0, "Bytes count only after the staged artifact was removed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let reader = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        reader.persistentStoreCoordinator = storage.container.persistentStoreCoordinator
        let stored = try XCTUnwrap(try reader.existingObject(with: unrelatedID) as? Imported)
        XCTAssertEqual(stored.name, "Before")
        XCTAssertEqual(unrelated.name, "Unsaved")
    }

    func testDuplicateOriginalsAndNoncanonicalRecoverySlotsFailClosed() throws {
        let (root, original, quarantine) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) } // try? ok: synthetic fixture cleanup
        XCTAssertThrowsError(try StagedAppDeletion(root: quarantine, originals: [(original, uri), (original, uri)]))
        let transaction = try StagedAppDeletion(root: quarantine, originals: [(original, uri)])
        try transaction.stage()
        for slot in ["../escape", "00", "1", "-1", "", "0/file"] {
            let entry = StagedAppDeletion.Entry(original: original, objectURI: uri, slot: slot)
            try JSONEncoder().encode([entry]).write(to: transaction.directory.appendingPathComponent("manifest.json"))
            let recovered = try StagedAppDeletion(directory: transaction.directory)
            XCTAssertThrowsError(try recovered.recover(rowExists: { _ in true }, allowedOriginal: { $0 == original }))
            XCTAssertEqual(try Data(contentsOf: transaction.directory.appendingPathComponent("0/file")), Data("original-bytes".utf8))
        }
    }

    func testRecoveryValidatesEveryOwnerBeforeRestoringAnyFile() throws {
        let (root, original, quarantine) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) } // try? ok: synthetic fixture cleanup
        let second = root.appendingPathComponent("Library/second")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let otherURI = URL(string: "x-coredata://test/Imported/p2")!
        let transaction = try StagedAppDeletion(root: quarantine, originals: [(original, uri), (second, otherURI)])
        try transaction.stage()
        XCTAssertThrowsError(try transaction.recover(rowExists: { value in
            if value == otherURI { throw CocoaError(.fileReadNoPermission) }
            return true
        }, allowedOriginal: { _ in true }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: transaction.directory.appendingPathComponent("0/file").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: transaction.directory.appendingPathComponent("1").path))
        XCTAssertThrowsError(try transaction.recover(rowExists: { _ in true }, allowedOriginal: { $0 == original }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
    }

    func testStageCannotFollowAnOriginalSymlink() throws {
        let (root, original, quarantine) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) } // try? ok: synthetic fixture cleanup
        let link = root.appendingPathComponent("Library/alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        let transaction = try StagedAppDeletion(root: quarantine, originals: [(link, uri)])
        XCTAssertThrowsError(try transaction.stage())
        XCTAssertEqual(try Data(contentsOf: original.appendingPathComponent("file")), Data("original-bytes".utf8))
    }

    func testTransactionRootCannotBeAnAlias() throws {
        let (root, original, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) } // try? ok: synthetic fixture cleanup
        let realRoot = root.appendingPathComponent("QuarantineTarget", isDirectory: true)
        try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: false)
        let alias = root.appendingPathComponent("QuarantineAlias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: realRoot)

        XCTAssertThrowsError(try StagedAppDeletion(root: alias, originals: [(original, uri)]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: realRoot.path), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.appendingPathComponent("file").path))
    }

    @MainActor
    func testALiveOperationRefusesDeletionBeforeMovingOrSaving() throws {
        let storage = Storage(inMemory: true)
        let row = Imported(context: storage.context); row.uuid = UUID().uuidString
        try storage.context.save()
        let directory = try XCTUnwrap(storage.getUuidDirectory(for: row))
        defer { try? FileManager.default.removeItem(at: directory) } // try? ok: unique test artifact cleanup
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("source".utf8).write(to: directory.appendingPathComponent("file"))
        let lease = try AppOperationRegistry.shared.acquire(AppOperationRegistry.key(row))
        withExtendedLifetime(lease) {
            XCTAssertFalse(storage.deleteApps([row], saveDeletion: { _ in XCTFail("A busy app cannot start a deletion transaction.") }))
            XCTAssertFalse(row.isDeleted)
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("file").path))
        }
    }

    @MainActor
    func testDeletingAnExactSlotPreservesOtherVersionsSourceAndSharedIdentity() throws {
        let storage = Storage(inMemory: true)
        let uuid = UUID().uuidString
        let imported = Imported(context: storage.context); imported.uuid = uuid
        imported.identifier = "com.example.app"
        let signed = Signed(context: storage.context); signed.uuid = uuid
        signed.identifier = "com.example.app"
        let otherVersion = Signed(context: storage.context); otherVersion.uuid = UUID().uuidString
        otherVersion.identifier = "com.example.app"
        let certificate = CertificatePair(context: storage.context); certificate.uuid = UUID().uuidString
        certificate.ppQCheck = false; certificate.isDefault = false; certificate.revoked = false
        signed.certificate = certificate; otherVersion.certificate = certificate
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ipa")
        try Data("original user-owned IPA".utf8).write(to: source)
        imported.source = source
        try storage.context.save()
        let certificateID = certificate.objectID
        let directories = try [imported as AppInfoPresentable, signed, otherVersion].map { try XCTUnwrap(storage.getUuidDirectory(for: $0)) }
        defer {
            for directory in directories { try? FileManager.default.removeItem(at: directory) } // try? ok: test-created slots only
            try? FileManager.default.removeItem(at: source) // try? ok: test-created source only
        }
        for (index, directory) in directories.enumerated() {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("slot-\(index)".utf8).write(to: directory.appendingPathComponent("file"))
        }
        XCTAssertTrue(storage.deleteApps([imported]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directories[0].path))
        XCTAssertEqual(try Data(contentsOf: directories[1].appendingPathComponent("file")), Data("slot-1".utf8))
        XCTAssertTrue(storage.deleteApps([signed]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directories[1].path))
        XCTAssertEqual(try Data(contentsOf: directories[2].appendingPathComponent("file")), Data("slot-2".utf8))
        XCTAssertEqual(try Data(contentsOf: source), Data("original user-owned IPA".utf8))
        XCTAssertFalse(certificate.isDeleted)
        XCTAssertNotNil(try storage.context.existingObject(with: certificateID))
        XCTAssertEqual(otherVersion.certificate?.objectID, certificate.objectID)
    }

    @MainActor
    func testDuplicateUUIDOwnershipRefusesDeletionRatherThanErasingASibling() throws {
        let storage = Storage(inMemory: true)
        let uuid = UUID().uuidString
        let first = Imported(context: storage.context); first.uuid = uuid
        let second = Imported(context: storage.context); second.uuid = uuid.lowercased()
        try storage.context.save()
        let directory = try XCTUnwrap(storage.getUuidDirectory(for: first))
        defer { try? FileManager.default.removeItem(at: directory) } // try? ok: unique test artifact cleanup
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertFalse(storage.deleteApps([first]))
        XCTAssertFalse(first.isDeleted); XCTAssertFalse(second.isDeleted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }

    @MainActor
    func testFailedBulkCommitRestoresEverySelectedArtifactAndReleasesLeases() throws {
        let storage = Storage(inMemory: true)
        let rows = (0..<2).map { _ -> Imported in
            let row = Imported(context: storage.context); row.uuid = UUID().uuidString; return row
        }
        try storage.context.save()
        let directories = try rows.map { try XCTUnwrap(storage.getUuidDirectory(for: $0)) }
        defer { for directory in directories { try? FileManager.default.removeItem(at: directory) } } // try? ok: test artifact cleanup
        for directory in directories { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        XCTAssertFalse(storage.deleteApps(rows.map { $0 as AppInfoPresentable }, saveDeletion: { _ in throw CocoaError(.fileWriteOutOfSpace) }))
        for (row, directory) in zip(rows, directories) {
            XCTAssertFalse(row.isDeleted)
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
            XCTAssertFalse(AppOperationRegistry.shared.isBusy(AppOperationRegistry.key(row)))
        }
    }
}
