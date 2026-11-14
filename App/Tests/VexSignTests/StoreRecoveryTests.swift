import XCTest
@testable import VexSign

final class StoreRecoveryTests: XCTestCase {
    func testQuarantineMovesSQLiteSidecarsAndPreservesAppAndCertificateFolders() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("StoreRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

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
        let root = fm.temporaryDirectory.appendingPathComponent("StoreRecoverySingle-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

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
}
