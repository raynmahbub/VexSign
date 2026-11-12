import XCTest
@testable import VexSign

final class TaskHistoryJournalTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("history.json")
    }
    private func snapshot(_ title: String) -> UnifiedTask.Snapshot {
        UnifiedTask(kind: .sign, title: title, phase: .signing).snapshot
    }

    func testCorruptJournalIsPreservedBeforeReplacement() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) } // try? ok: test teardown only
        let corrupt = Data("not valid JSON".utf8)
        try corrupt.write(to: url)
        let journal = TaskHistoryJournal(url: url)
        guard case .loaded(_, warning: .corruptPreserved) = await journal.load() else { return XCTFail("Expected preserved corruption") }
        let result = await journal.save([snapshot("new")])
        XCTAssertNil(result)
        let backup = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("TaskHistory-recovery-") })
        XCTAssertEqual(try Data(contentsOf: backup), corrupt)
        XCTAssertEqual(try JSONDecoder().decode([UnifiedTask.Snapshot].self, from: Data(contentsOf: url)).first?.title, "new")
    }

    func testInaccessibleReadBlocksWritesUntilSuccessfulReload() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) } // try? ok: test teardown only
        let original = try JSONEncoder().encode([snapshot("original")])
        try original.write(to: url)
        var io = TaskHistoryJournal.IO()
        var reads = 0 // Accessed only by the journal's serial queue.
        io.read = { url in
            reads += 1
            if reads == 1 { throw CocoaError(.fileReadNoPermission) }
            return try Data(contentsOf: url)
        }
        let journal = TaskHistoryJournal(url: url, io: io)
        guard case .blocked(.inaccessible) = await journal.load() else { return XCTFail("Expected inaccessible, not corruption") }
        let blocked = await journal.save([])
        XCTAssertEqual(blocked, .notLoaded)
        XCTAssertEqual(try Data(contentsOf: url), original)
        guard case .loaded(let snapshots, warning: nil) = await journal.load() else { return XCTFail("Expected reload") }
        XCTAssertEqual(snapshots.first?.title, "original")
        let saved = await journal.save(snapshots)
        XCTAssertNil(saved)
    }

    func testFailedPreservationCannotOverwriteOriginal() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) } // try? ok: test teardown only
        let original = Data("corrupt".utf8)
        try original.write(to: url)
        var io = TaskHistoryJournal.IO()
        io.preserve = { _ in throw CocoaError(.fileWriteOutOfSpace) }
        let journal = TaskHistoryJournal(url: url, io: io)
        guard case .blocked(.preservationFailed) = await journal.load() else { return XCTFail("Expected blocked preservation") }
        let result = await journal.save([])
        XCTAssertEqual(result, .notLoaded)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testQueuedWritesRemainOrderedAndRunOffMainThread() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) } // try? ok: test teardown only
        var io = TaskHistoryJournal.IO()
        let realWrite = io.write
        io.write = { data, url in
            XCTAssertFalse(Thread.isMainThread)
            try realWrite(data, url)
        }
        let journal = TaskHistoryJournal(url: url, io: io)
        _ = await journal.load()
        for index in 0..<25 { 
            let issue = await journal.save([snapshot(String(index))])
            XCTAssertNil(issue)
        }
        // A final save is a barrier for all preceding FIFO writes.
        let result = await journal.save([snapshot("last")])
        XCTAssertNil(result)
        XCTAssertEqual(try JSONDecoder().decode([UnifiedTask.Snapshot].self, from: Data(contentsOf: url)).first?.title, "last")
    }

    func testFailedWriteRetainsPriorJournalAndLaterSaveCanRetry() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) } // try? ok: test teardown only
        let original = try JSONEncoder().encode([snapshot("before")])
        try original.write(to: url)
        var io = TaskHistoryJournal.IO()
        let realWrite = io.write
        var writes = 0 // Queue-confined.
        io.write = { data, url in
            writes += 1
            if writes == 1 { throw CocoaError(.fileWriteOutOfSpace) }
            try realWrite(data, url)
        }
        let journal = TaskHistoryJournal(url: url, io: io)
        _ = await journal.load()
        let failed = await journal.save([snapshot("after")])
        XCTAssertEqual(failed, .writeFailed)
        XCTAssertEqual(try Data(contentsOf: url), original)
        let retried = await journal.save([snapshot("after")])
        XCTAssertNil(retried)
        XCTAssertEqual(try JSONDecoder().decode([UnifiedTask.Snapshot].self, from: Data(contentsOf: url)).first?.title, "after")
    }

    func testEncodingFailureDoesNotReplacePreviousBytes() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) } // try? ok: test teardown only
        let original = try JSONEncoder().encode([snapshot("before")])
        try original.write(to: url)
        let journal = TaskHistoryJournal(url: url)
        _ = await journal.load()
        var invalid = snapshot("invalid")
        invalid.updatedAt = Date(timeIntervalSince1970: .infinity)
        let result = await journal.save([invalid])
        XCTAssertEqual(result, .writeFailed)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testReloadedInFlightTaskRecoversAsInterruptedWithoutRetry() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) } // try? ok: test teardown only
        let journal = TaskHistoryJournal(url: url)
        _ = await journal.load()
        let result = await journal.save([snapshot("in flight")])
        XCTAssertNil(result)
        guard case .loaded(let snapshots, _) = await TaskHistoryJournal(url: url).load() else { return XCTFail("Expected persisted task") }
        let task = UnifiedTask.from(try XCTUnwrap(snapshots.first))
        task.recoverAfterRestart()
        XCTAssertEqual(task.phase, .interrupted)
        XCTAssertEqual(task.failureStage, .signing)
    }
}
