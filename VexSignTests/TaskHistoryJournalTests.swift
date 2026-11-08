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
    private func load(_ journal: TaskHistoryJournal) async -> TaskHistoryJournal.LoadResult {
        await withCheckedContinuation { continuation in journal.load { continuation.resume(returning: $0) } }
    }
    private func save(_ journal: TaskHistoryJournal, _ snapshots: [UnifiedTask.Snapshot]) async -> TaskHistoryJournal.Issue? {
        await withCheckedContinuation { continuation in journal.save(snapshots) { continuation.resume(returning: $0) } }
    }

    func testCorruptJournalIsPreservedBeforeReplacement() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) } // try? ok: test teardown only
        let corrupt = Data("not valid JSON".utf8)
        try corrupt.write(to: url)
        let journal = TaskHistoryJournal(url: url)
        guard case .loaded(_, warning: .corruptPreserved) = await load(journal) else { return XCTFail("Expected preserved corruption") }
        let result = await save(journal, [snapshot("new")])
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
        guard case .blocked(.inaccessible) = await load(journal) else { return XCTFail("Expected inaccessible, not corruption") }
        let blocked = await save(journal, [])
        XCTAssertEqual(blocked, .notLoaded)
        XCTAssertEqual(try Data(contentsOf: url), original)
        guard case .loaded(let snapshots, warning: nil) = await load(journal) else { return XCTFail("Expected reload") }
        XCTAssertEqual(snapshots.first?.title, "original")
        let saved = await save(journal, snapshots)
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
        guard case .blocked(.preservationFailed) = await load(journal) else { return XCTFail("Expected blocked preservation") }
        let result = await save(journal, [])
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
        _ = await load(journal)
        for index in 0..<25 { journal.save([snapshot(String(index))]) { XCTAssertNil($0) } }
        // A final save is a barrier for all preceding FIFO writes.
        let result = await save(journal, [snapshot("last")])
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
        _ = await load(journal)
        let failed = await save(journal, [snapshot("after")])
        XCTAssertEqual(failed, .writeFailed)
        XCTAssertEqual(try Data(contentsOf: url), original)
        let retried = await save(journal, [snapshot("after")])
        XCTAssertNil(retried)
        XCTAssertEqual(try JSONDecoder().decode([UnifiedTask.Snapshot].self, from: Data(contentsOf: url)).first?.title, "after")
    }

    func testEncodingFailureDoesNotReplacePreviousBytes() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) } // try? ok: test teardown only
        let original = try JSONEncoder().encode([snapshot("before")])
        try original.write(to: url)
        let journal = TaskHistoryJournal(url: url)
        _ = await load(journal)
        var invalid = snapshot("invalid")
        invalid.updatedAt = Date(timeIntervalSince1970: .infinity)
        let result = await save(journal, [invalid])
        XCTAssertEqual(result, .writeFailed)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testReloadedInFlightTaskRecoversAsInterruptedWithoutRetry() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) } // try? ok: test teardown only
        let journal = TaskHistoryJournal(url: url)
        _ = await load(journal)
        let result = await save(journal, [snapshot("in flight")])
        XCTAssertNil(result)
        guard case .loaded(let snapshots, _) = await load(TaskHistoryJournal(url: url)) else { return XCTFail("Expected persisted task") }
        let task = UnifiedTask.from(try XCTUnwrap(snapshots.first))
        task.recoverAfterRestart()
        XCTAssertEqual(task.phase, .interrupted)
        XCTAssertEqual(task.failureStage, .signing)
    }
}
