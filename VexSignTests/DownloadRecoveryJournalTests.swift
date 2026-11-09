import XCTest
@testable import VexSign

final class DownloadRecoveryJournalTests: XCTestCase {
    func testRoundTripCheckpointAndExplicitForget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) } // try? ok: test teardown
        let journal = DownloadRecoveryJournal(root: root)
        XCTAssertTrue(try journal.load().isEmpty)
        let record = DownloadRecoveryJournal.Record(id: UUID(), name: "Fixture.ipa", sourceURL: URL(string: "https://example.invalid/a.ipa"),
                                                     expectedBytes: 42, expectedHash: nil, stage: .importing,
                                                     stagedName: "Fixture.ipa", updatedAt: Date())
        try journal.save(record)
        XCTAssertEqual(try journal.load().first?.stage, .importing)
        XCTAssertEqual(try journal.load().first?.expectedBytes, 42)
        XCTAssertEqual(try journal.retainedStagingNames(), ["Fixture.ipa"])
        try journal.remove(record.id)
        XCTAssertTrue(try journal.load().isEmpty)
    }

    func testCredentialAndTokenURLsAreNotPersisted() {
        XCTAssertNil(DownloadRecoveryJournal.publicURL(URL(string: "https://example.invalid/a?token=secret")!))
        XCTAssertNil(DownloadRecoveryJournal.publicURL(URL(string: "https://user:pass@example.invalid/a")!))
        XCTAssertNil(DownloadRecoveryJournal.publicURL(URL(string: "http://example.invalid/a")!))
    }

    func testTraversalAndSymlinkRecoveryInputsAreRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) } // try? ok: test teardown
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let journal = DownloadRecoveryJournal(root: root)
        var record = DownloadRecoveryJournal.Record(id: UUID(), name: "a", sourceURL: nil, expectedBytes: nil,
                                                    expectedHash: nil, stage: .verifying, stagedName: "../escape.ipa", updatedAt: Date())
        XCTAssertNil(journal.stagedFile(for: record, in: root))
        let target = root.appendingPathComponent("target.ipa")
        try Data([1]).write(to: target)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias.ipa"), withDestinationURL: target)
        record.stagedName = "alias.ipa"
        XCTAssertNil(journal.stagedFile(for: record, in: root))
        record.stagedName = "target.ipa"
        XCTAssertEqual(journal.stagedFile(for: record, in: root), target)
    }

    @MainActor
    func testCommitIntentIsDurableAndWriteFailureBlocksOnlyBeforeCommit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) } // try? ok: test teardown
        let journal = DownloadRecoveryJournal(root: root)
        let manager = DownloadManager(configureServices: false)
        manager.recoveryJournal = journal
        let download = Download(id: "commit-fixture", url: URL(string: "https://example.invalid/a.ipa")!)
        manager.downloads.append(download)
        manager.ownImportRecovery(download)
        let uuid = UUID().uuidString
        try download.importCommitCheckpoint?(uuid, false)
        XCTAssertEqual(try journal.load().first?.stage, .committing)
        XCTAssertEqual(try journal.load().first?.libraryUUID, uuid)
        XCTAssertFalse(try XCTUnwrap(journal.load().first).canReverify)
        try download.importCommitCheckpoint?(uuid, true)
        XCTAssertEqual(try journal.load().first?.stage, .committed)
        try FileManager.default.removeItem(at: root)
        try Data([1]).write(to: root) // A file in place of the directory injects a write failure.
        XCTAssertThrowsError(try download.importCommitCheckpoint?(uuid, false))
        XCTAssertNoThrow(try download.importCommitCheckpoint?(uuid, true))
        XCTAssertNotNil(manager.recoveryWarning)
    }

    func testOnlyPreCommitPhasesCanReverify() {
        for stage in [DownloadRecoveryJournal.Stage.downloading, .verifying, .awaitingDecision, .importing, .committing, .committed] {
            let record = DownloadRecoveryJournal.Record(id: UUID(), name: "a", sourceURL: nil, expectedBytes: nil, expectedHash: nil,
                                                       stage: stage, stagedName: nil, updatedAt: Date())
            XCTAssertEqual(record.canReverify, stage == .verifying || stage == .awaitingDecision)
        }
    }

    func testResumeDataIsBoundToOwnerURLAndForgetRemovesIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) } // try? ok: test teardown
        let journal = DownloadRecoveryJournal(root: root)
        let id = UUID()
        let url = URL(string: "https://example.invalid/a.ipa")!
        let data = try PropertyListSerialization.data(fromPropertyList: ["NSURLSessionDownloadInfoURL": url.absoluteString], format: .binary, options: 0)
        try journal.saveResumeData(data, id: id, source: url)
        XCTAssertEqual(try journal.resumeData(id: id, source: url), data)
        XCTAssertNil(try journal.resumeData(id: id, source: URL(string: "https://example.invalid/b.ipa")!))
        try journal.saveResumeData(Data("unknown system format".utf8), id: id, source: url)
        XCTAssertNil(try journal.resumeData(id: id, source: url))
        try journal.remove(id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(id.uuidString + ".resume").path))
        try journal.saveResumeData(data, id: id, source: URL(string: "https://example.invalid/a.ipa?token=secret")!)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(id.uuidString + ".resume").path))
    }

    func testCorruptRecordsAreNotDeleted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) } // try? ok: test teardown
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent(UUID().uuidString + ".json")
        try Data("corrupt".utf8).write(to: path)
        XCTAssertThrowsError(try DownloadRecoveryJournal(root: root).load())
        XCTAssertEqual(try Data(contentsOf: path), Data("corrupt".utf8))
    }
}
