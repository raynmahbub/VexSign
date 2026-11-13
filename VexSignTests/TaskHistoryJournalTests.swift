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

    // MARK: - One unreadable record must not take the rest of the history with it

    /// A valid history array whose second element is not a task record.
    private func journalWithOneUnreadableRecord() throws -> (url: URL, original: Data) {
        let url = try fixture()
        let good = try JSONEncoder().encode([snapshot("kept")])
        var elements = try XCTUnwrap(JSONSerialization.jsonObject(with: good) as? [Any])
        elements.append(["id": 42, "kind": false])   // wrong types: cannot be a snapshot
        let original = try JSONSerialization.data(withJSONObject: elements)
        try original.write(to: url)
        return (url, original)
    }

    func testOneUnreadableRecordDoesNotDiscardTheReadableHistory() async throws {
        let (url, _) = try journalWithOneUnreadableRecord()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) } // try? ok: test teardown only
        let journal = TaskHistoryJournal(url: url)

        guard case .loaded(let snapshots, warning: .recordsDropped) = await journal.load() else {
            return XCTFail("Expected the readable record to be salvaged, not the whole file dropped")
        }
        XCTAssertEqual(snapshots.map(\.title), ["kept"])

        // Salvage is a read, not a licence to overwrite: writing the salvaged set is allowed only
        // because the original was preserved first.
        let saved = await journal.save(snapshots)
        XCTAssertNil(saved)
        let recovered = try JSONDecoder().decode([UnifiedTask.Snapshot].self, from: Data(contentsOf: url))
        XCTAssertEqual(recovered.map(\.title), ["kept"])
    }

    func testSalvagePreservesTheOriginalFileByteForByte() async throws {
        let (url, original) = try journalWithOneUnreadableRecord()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) } // try? ok: test teardown only
        let journal = TaskHistoryJournal(url: url)

        guard case .loaded(_, warning: .recordsDropped) = await journal.load() else {
            return XCTFail("Expected a salvage")
        }
        let backup = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent.hasPrefix("TaskHistory-recovery-") },
            "the dropped record must still exist somewhere"
        )
        XCTAssertEqual(try Data(contentsOf: backup), original)
    }

    func testSalvageBlocksWritesWhenTheOriginalCannotBePreserved() async throws {
        let (url, original) = try journalWithOneUnreadableRecord()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) } // try? ok: test teardown only
        var io = TaskHistoryJournal.IO()
        io.preserve = { _ in throw CocoaError(.fileWriteOutOfSpace) }
        let journal = TaskHistoryJournal(url: url, io: io)

        guard case .blocked(.preservationFailed) = await journal.load() else {
            return XCTFail("Expected blocked, not a salvage that cannot be backed up")
        }
        XCTAssertEqual(await journal.save([]), .notLoaded, "an unbacked-up salvage must not overwrite the original")
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testAValidJSONDocumentThatIsNotAnArrayIsStillCorruption() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) } // try? ok: test teardown only
        let original = Data(#"{"tasks":[]}"#.utf8)
        try original.write(to: url)
        let journal = TaskHistoryJournal(url: url)

        guard case .loaded([], warning: .corruptPreserved) = await journal.load() else {
            return XCTFail("An object is not a history file; it must not be read as an empty history")
        }
        let backup = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent.hasPrefix("TaskHistory-recovery-") }
        )
        XCTAssertEqual(try Data(contentsOf: backup), original)
    }
