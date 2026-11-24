import CoreData
import XCTest
@testable import VexSign

final class StoreRecoveryTests: XCTestCase {
    private enum SimulatedError: Error {
        case moveBlocked
        case rollbackBlocked
    }

    private func makeTempRoot(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }

    func testQuarantineMovesSQLiteSidecarsAndPreservesAppAndCertificateFolders() throws {
        let fm = FileManager.default
        let root = try makeTempRoot("StoreRecoveryTests")

        let storeURL = root.appendingPathComponent("VexSign.sqlite")
        let walURL = root.appendingPathComponent("VexSign.sqlite-wal")
        let shmURL = root.appendingPathComponent("VexSign.sqlite-shm")
        try Data("corrupt-db".utf8).write(to: storeURL)
        try Data("wal".utf8).write(to: walURL)
        try Data("shm".utf8).write(to: shmURL)

        let signedDir = root.appendingPathComponent("signed", isDirectory: true)
        let unsignedDir = root.appendingPathComponent("unsigned", isDirectory: true)
        let certsDir = root.appendingPathComponent("certificates", isDirectory: true)
        try fm.createDirectory(at: signedDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: unsignedDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: certsDir, withIntermediateDirectories: true)

        let certFile = certsDir.appendingPathComponent("identity.p12")
        let ipaFile = signedDir.appendingPathComponent("App.app")
        let importedFile = unsignedDir.appendingPathComponent("Raw.app")
        try Data("p12-bytes".utf8).write(to: certFile)
        try Data("signed-bytes".utf8).write(to: ipaFile)
        try Data("unsigned-bytes".utf8).write(to: importedFile)

        let quarantineRoot = root.appendingPathComponent("QuarantinedStores", isDirectory: true)
        let outcome = try XCTUnwrap(
            CoreDataStoreRecovery.quarantineStore(
                at: storeURL,
                quarantineRoot: quarantineRoot,
                reason: "SQLite file is malformed"
            )
        )

        XCTAssertFalse(fm.fileExists(atPath: storeURL.path))
        XCTAssertFalse(fm.fileExists(atPath: walURL.path))
        XCTAssertFalse(fm.fileExists(atPath: shmURL.path))
        XCTAssertEqual(outcome.movedFiles.count, 3)

        XCTAssertTrue(fm.fileExists(atPath: outcome.quarantineDirectory.appendingPathComponent("VexSign.sqlite").path))
        XCTAssertTrue(fm.fileExists(atPath: outcome.quarantineDirectory.appendingPathComponent("VexSign.sqlite-wal").path))
        XCTAssertTrue(fm.fileExists(atPath: outcome.quarantineDirectory.appendingPathComponent("VexSign.sqlite-shm").path))

        XCTAssertTrue(fm.fileExists(atPath: certFile.path))
        XCTAssertTrue(fm.fileExists(atPath: ipaFile.path))
        XCTAssertTrue(fm.fileExists(atPath: importedFile.path))
    }

    func testQuarantineHandlesSingleSQLiteWithoutSidecarsAndRedactsNotice() throws {
        let fm = FileManager.default
        let root = try makeTempRoot("StoreRecoverySingle")

        let storeURL = root.appendingPathComponent("VexSign.sqlite")
        try Data("broken-sqlite".utf8).write(to: storeURL)

        let quarantineRoot = root.appendingPathComponent("QuarantinedStores", isDirectory: true)
        let outcome = try XCTUnwrap(
            CoreDataStoreRecovery.quarantineStore(
                at: storeURL,
                quarantineRoot: quarantineRoot,
                reason: "Failed to open /private/var/mobile/Containers/Data/VexSign.sqlite"
            )
        )

        XCTAssertEqual(outcome.movedFiles.count, 1)
        XCTAssertFalse(fm.fileExists(atPath: storeURL.path))
        XCTAssertTrue(fm.fileExists(atPath: outcome.quarantineDirectory.appendingPathComponent("VexSign.sqlite").path))
        XCTAssertFalse(outcome.notice.summary.contains("/private/var/mobile"))
    }

    func testQuarantineReturnsNilWhenStoreURLIsNil() throws {
        let outcome = try CoreDataStoreRecovery.quarantineStore(at: nil, reason: "Missing URL")
        XCTAssertNil(outcome)
    }

    func testQuarantineFailureOnMainSQLiteLeavesOriginalsIntactAndRemovesEmptyFolder() throws {
        let fm = FileManager.default
        let root = try makeTempRoot("StoreRecoveryFailMain")
        let storeURL = root.appendingPathComponent("VexSign.sqlite")
        let walURL = root.appendingPathComponent("VexSign.sqlite-wal")
        let shmURL = root.appendingPathComponent("VexSign.sqlite-shm")
        try Data("sqlite-data".utf8).write(to: storeURL)
        try Data("wal-data".utf8).write(to: walURL)
        try Data("shm-data".utf8).write(to: shmURL)

        let quarantineRoot = root.appendingPathComponent("QuarantinedStores", isDirectory: true)

        XCTAssertThrowsError(
            try CoreDataStoreRecovery.quarantineStore(
                at: storeURL,
                quarantineRoot: quarantineRoot,
                reason: "Corrupt",
                moveItem: { source, destination in
                    if source.lastPathComponent == "VexSign.sqlite" {
                        throw SimulatedError.moveBlocked
                    }
                    try fm.moveItem(at: source, to: destination)
                }
            )
        ) { error in
            guard case let CoreDataStoreRecovery.QuarantineError.moveFailed(fileName, _, rollbackFailures) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(fileName, "VexSign.sqlite")
            XCTAssertTrue(rollbackFailures.isEmpty)
        }

        XCTAssertEqual(try Data(contentsOf: storeURL), Data("sqlite-data".utf8))
        XCTAssertEqual(try Data(contentsOf: walURL), Data("wal-data".utf8))
        XCTAssertEqual(try Data(contentsOf: shmURL), Data("shm-data".utf8))
        XCTAssertTrue(CoreDataStoreRecovery.listQuarantinedStores(in: quarantineRoot).isEmpty)
    }

    func testQuarantineFailureOnWALRollsBackMovedSQLite() throws {
        let fm = FileManager.default
        let root = try makeTempRoot("StoreRecoveryFailWAL")
        let storeURL = root.appendingPathComponent("VexSign.sqlite")
        let walURL = root.appendingPathComponent("VexSign.sqlite-wal")
        let shmURL = root.appendingPathComponent("VexSign.sqlite-shm")
        try Data("sqlite-bytes-v1".utf8).write(to: storeURL)
        try Data("wal-bytes-v1".utf8).write(to: walURL)
        try Data("shm-bytes-v1".utf8).write(to: shmURL)

        let quarantineRoot = root.appendingPathComponent("QuarantinedStores", isDirectory: true)

        XCTAssertThrowsError(
            try CoreDataStoreRecovery.quarantineStore(
                at: storeURL,
                quarantineRoot: quarantineRoot,
                reason: "Corrupt WAL",
                moveItem: { source, destination in
                    if source.lastPathComponent == "VexSign.sqlite-wal" {
                        throw SimulatedError.moveBlocked
                    }
                    try fm.moveItem(at: source, to: destination)
                }
            )
        ) { error in
            guard case let CoreDataStoreRecovery.QuarantineError.moveFailed(fileName, _, rollbackFailures) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(fileName, "VexSign.sqlite-wal")
            XCTAssertTrue(rollbackFailures.isEmpty)
        }

        XCTAssertEqual(try Data(contentsOf: storeURL), Data("sqlite-bytes-v1".utf8))
        XCTAssertEqual(try Data(contentsOf: walURL), Data("wal-bytes-v1".utf8))
        XCTAssertEqual(try Data(contentsOf: shmURL), Data("shm-bytes-v1".utf8))
        XCTAssertTrue(CoreDataStoreRecovery.listQuarantinedStores(in: quarantineRoot).isEmpty)
    }

    func testQuarantineFailureOnSHMRollsBackBothSQLiteAndWAL() throws {
        let fm = FileManager.default
        let root = try makeTempRoot("StoreRecoveryFailSHM")
        let storeURL = root.appendingPathComponent("VexSign.sqlite")
        let walURL = root.appendingPathComponent("VexSign.sqlite-wal")
        let shmURL = root.appendingPathComponent("VexSign.sqlite-shm")
        try Data("sqlite-bytes-v2".utf8).write(to: storeURL)
        try Data("wal-bytes-v2".utf8).write(to: walURL)
        try Data("shm-bytes-v2".utf8).write(to: shmURL)

        let quarantineRoot = root.appendingPathComponent("QuarantinedStores", isDirectory: true)

        XCTAssertThrowsError(
            try CoreDataStoreRecovery.quarantineStore(
                at: storeURL,
                quarantineRoot: quarantineRoot,
                reason: "Corrupt SHM",
                moveItem: { source, destination in
                    if source.lastPathComponent == "VexSign.sqlite-shm" {
                        throw SimulatedError.moveBlocked
                    }
                    try fm.moveItem(at: source, to: destination)
                }
            )
        ) { error in
            guard case let CoreDataStoreRecovery.QuarantineError.moveFailed(fileName, _, rollbackFailures) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(fileName, "VexSign.sqlite-shm")
            XCTAssertTrue(rollbackFailures.isEmpty)
        }

        XCTAssertEqual(try Data(contentsOf: storeURL), Data("sqlite-bytes-v2".utf8))
        XCTAssertEqual(try Data(contentsOf: walURL), Data("wal-bytes-v2".utf8))
        XCTAssertEqual(try Data(contentsOf: shmURL), Data("shm-bytes-v2".utf8))
        XCTAssertTrue(CoreDataStoreRecovery.listQuarantinedStores(in: quarantineRoot).isEmpty)
    }

    func testQuarantineRollbackFailureReportsUnrestoredFileNames() throws {
        let fm = FileManager.default
        let root = try makeTempRoot("StoreRecoveryRollbackFail")
        let storeURL = root.appendingPathComponent("VexSign.sqlite")
        let walURL = root.appendingPathComponent("VexSign.sqlite-wal")
        try Data("sqlite".utf8).write(to: storeURL)
        try Data("wal".utf8).write(to: walURL)

        let quarantineRoot = root.appendingPathComponent("QuarantinedStores", isDirectory: true)

        XCTAssertThrowsError(
            try CoreDataStoreRecovery.quarantineStore(
                at: storeURL,
                quarantineRoot: quarantineRoot,
                reason: "Corrupt",
                moveItem: { source, destination in
                    if source.lastPathComponent == "VexSign.sqlite-wal" {
                        throw SimulatedError.moveBlocked
                    }
                    try fm.moveItem(at: source, to: destination)
                },
                rollbackMove: { _, _ in
                    throw SimulatedError.rollbackBlocked
                }
            )
        ) { error in
            guard case let CoreDataStoreRecovery.QuarantineError.moveFailed(fileName, _, rollbackFailures) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(fileName, "VexSign.sqlite-wal")
            XCTAssertEqual(rollbackFailures, ["VexSign.sqlite"])
        }
    }

    func testQuarantinedStoresCanBeListedAndExportedNonDestructively() throws {
        let fm = FileManager.default
        let root = try makeTempRoot("StoreRecoveryExport")
        let storeURL = root.appendingPathComponent("VexSign.sqlite")
        let walURL = root.appendingPathComponent("VexSign.sqlite-wal")
        try Data("quarantined-db".utf8).write(to: storeURL)
        try Data("quarantined-wal".utf8).write(to: walURL)

        let quarantineRoot = root.appendingPathComponent("QuarantinedStores", isDirectory: true)
        _ = try XCTUnwrap(
            CoreDataStoreRecovery.quarantineStore(
                at: storeURL,
                quarantineRoot: quarantineRoot,
                reason: "Unreadable database"
            )
        )

        let stores = CoreDataStoreRecovery.listQuarantinedStores(in: quarantineRoot)
        XCTAssertEqual(stores.count, 1)
        XCTAssertEqual(stores[0].files.map(\.lastPathComponent), ["VexSign.sqlite", "VexSign.sqlite-wal"])

        let exportRoot = root.appendingPathComponent("Export", isDirectory: true)
        let exported = try CoreDataStoreRecovery.exportQuarantinedStore(stores[0], to: exportRoot)
        XCTAssertEqual(try Data(contentsOf: exported.appendingPathComponent("VexSign.sqlite")), Data("quarantined-db".utf8))
        XCTAssertEqual(try Data(contentsOf: exported.appendingPathComponent("VexSign.sqlite-wal")), Data("quarantined-wal".utf8))
        XCTAssertTrue(fm.fileExists(atPath: stores[0].directoryURL.appendingPathComponent("VexSign.sqlite").path))
    }

    func testUnavailablePersistentStorageDisablesWritesAndKeepsWarningVisible() async throws {
        let root = try makeTempRoot("StoreUnavailable")
        let storeURL = root.appendingPathComponent("VexSign.sqlite")
        try Data("corrupt-store".utf8).write(to: storeURL)
        let quarantineRoot = root.appendingPathComponent("QuarantinedStores", isDirectory: true)

        let storage = Storage(
            storeURL: storeURL,
            quarantineRoot: quarantineRoot,
            forcePersistentStoreFailure: true
        )

        XCTAssertTrue(storage.isPersistentStorageUnavailable)
        XCTAssertNotNil(storage.persistentStorageUnavailableError)
        XCTAssertEqual(storage.recoveryNotice?.isPersistentStorageUnavailable, true)

        storage.acknowledgeRecoveryNotice()
        XCTAssertNotNil(
            storage.recoveryNotice,
            "Persistent storage unavailability notice must stay visible while writes are disabled."
        )

        do {
            _ = try await storage.write { context in
                let imported = Imported(context: context)
                imported.uuid = UUID().uuidString
                imported.name = "ShouldNotPersist"
                imported.date = Date()
                return imported
            }
            XCTFail("Expected write to throw persistentStorageUnavailable")
        } catch let error as Storage.PersistenceError {
            guard case .persistentStorageUnavailable = error else {
                return XCTFail("Unexpected persistence error: \(error)")
            }
        }
    }

    func testCorruptSQLiteRecoveryOpensFreshStoreAndPersistsAcrossRestart() async throws {
        let root = try makeTempRoot("StoreRestartRecovery")
        let storeURL = root.appendingPathComponent("VexSign.sqlite")
        let quarantineRoot = root.appendingPathComponent("QuarantinedStores", isDirectory: true)
        try Data("not-a-valid-sqlite-database-header-at-all".utf8).write(to: storeURL)

        let recoveredStorage = Storage(storeURL: storeURL, quarantineRoot: quarantineRoot)
        XCTAssertFalse(recoveredStorage.isPersistentStorageUnavailable)
        XCTAssertNotNil(recoveredStorage.recoveryNotice)
        XCTAssertEqual(recoveredStorage.quarantinedStores().count, 1)

        let persistedUUID = UUID().uuidString
        _ = try await recoveredStorage.write { context in
            let imported = Imported(context: context)
            imported.uuid = persistedUUID
            imported.name = "RecoveredApp"
            imported.identifier = "com.vexsign.recovered"
            imported.version = "1.0"
            imported.date = Date()
            return imported
        }

        // Reopen the store from disk as a simulated app restart.
        let restartedStorage = Storage(storeURL: storeURL, quarantineRoot: quarantineRoot)
        XCTAssertFalse(restartedStorage.isPersistentStorageUnavailable)
        XCTAssertNil(restartedStorage.recoveryNotice)

        let fetch: NSFetchRequest<Imported> = Imported.fetchRequest()
        fetch.predicate = NSPredicate(format: "uuid == %@", persistedUUID)
        let rows = try restartedStorage.fetchOnQueueThrowing(fetch)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.name, "RecoveredApp")
        XCTAssertEqual(restartedStorage.quarantinedStores().count, 1)
    }
}
