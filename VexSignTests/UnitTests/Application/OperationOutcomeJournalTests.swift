import XCTest
@testable import VexSign

private final class JournalStorage: @unchecked Sendable {
    var data: Data?
}

final class OperationOutcomeJournalTests: XCTestCase {
    private func record(id: String = UUID().uuidString, reason: String? = nil) -> OperationOutcomeRecord {
        OperationOutcomeRecord(
            correlationID: id,
            operation: "accountRefresh",
            stage: AccountRefreshStage.verify.rawValue,
            status: .unconfirmed,
            reason: reason,
            startedAt: Date(timeIntervalSince1970: 2_000_000_000),
            finishedAt: Date(timeIntervalSince1970: 2_000_000_001)
        )
    }

    func testExportedHistoryContainsOnlySanitizedStageFacts() async throws {
        let storage = JournalStorage()
        let url = URL(fileURLWithPath: "/tmp/operation-outcomes-test.json")
        let io = OperationOutcomeJournal.IO(
            read: { _ in storage.data ?? Data() },
            write: { data, _ in storage.data = data }
        )
        let journal = OperationOutcomeJournal(url: url, io: io)
        await journal.record(record(reason: "person@example.com password=hunter2 failed"))

        let data = await journal.exportJSON()
        let decoded = try XCTUnwrap(JSONDecoder().decode([OperationOutcomeRecord].self, from: data))
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.stage, "verify")
        XCTAssertEqual(decoded.first?.status, .unconfirmed)
        XCTAssertFalse(decoded.first?.reason?.contains("person@example.com") == true)
        XCTAssertFalse(decoded.first?.reason?.contains("hunter2") == true)
    }

    func testMalformedCorrelationIDsAreNotPersisted() async {
        let storage = JournalStorage()
        let url = URL(fileURLWithPath: "/tmp/operation-outcomes-test.json")
        let io = OperationOutcomeJournal.IO(
            read: { _ in storage.data ?? Data() },
            write: { data, _ in storage.data = data }
        )
        let journal = OperationOutcomeJournal(url: url, io: io)
        await journal.record(record(id: "not-an-id;drop"))
        let all = await journal.all()
        XCTAssertTrue(all.isEmpty)
        XCTAssertNil(storage.data)
    }

    func testHistoryIsBounded() async {
        let storage = JournalStorage()
        let url = URL(fileURLWithPath: "/tmp/operation-outcomes-test.json")
        let io = OperationOutcomeJournal.IO(
            read: { _ in storage.data ?? Data() },
            write: { data, _ in storage.data = data }
        )
        let journal = OperationOutcomeJournal(url: url, io: io)
        for _ in 0..<(OperationOutcomeJournal.limit + 5) {
            await journal.record(record())
        }
        let all = await journal.all()
        XCTAssertEqual(all.count, OperationOutcomeJournal.limit)
    }
}
