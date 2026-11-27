import Foundation
import XCTest
import os
@testable import VexSign

final class DiagnosticEventJournalTests: XCTestCase {
    private struct MemoryState: Sendable {
        var data: Data?
        var quarantined: Data?
    }

    private func memoryIO(_ state: OSAllocatedUnfairLock<MemoryState>) -> DiagnosticEventJournal.IO {
        var io = DiagnosticEventJournal.IO()
        io.read = { _ in
            guard let data = state.withLock({ $0.data }) else { throw CocoaError(.fileReadNoPermission) }
            return data
        }
        io.write = { data, _ in state.withLock { $0.data = data } }
        io.remove = { _ in state.withLock { $0.data = nil } }
        io.move = { _, _ in
            let current = state.withLock { $0.data }
            state.withLock {
                $0.quarantined = current
                $0.data = nil
            }
        }
        return io
    }

    private func event(_ index: Int) -> DiagnosticEvent {
        .make(
            code: DiagnosticEventCode.appHealth,
            severity: .info,
            category: .app,
            userMessage: "Event \(index)"
        )
    }

    func testJournalBoundsRetention() async {
        let state = OSAllocatedUnfairLock(initialState: MemoryState())
        let journal = DiagnosticEventJournal(io: memoryIO(state))
        for index in 0..<(DiagnosticEventJournal.limit + 10) {
            await journal.record(event(index))
        }
        let all = await journal.all()
        XCTAssertEqual(all.count, DiagnosticEventJournal.limit)
        XCTAssertEqual(all.first?.userMessage, "Event 10")
    }

    func testCorruptHistoryIsQuarantinedNotTrusted() async throws {
        let corrupt = Data("not a diagnostic journal".utf8)
        let state = OSAllocatedUnfairLock(initialState: MemoryState(data: corrupt))
        let journal = DiagnosticEventJournal(io: memoryIO(state))
        let all = await journal.all()
        XCTAssertTrue(all.isEmpty)
        XCTAssertEqual(state.withLock { $0.quarantined }, corrupt)
        let notice = await journal.consumeRecoveryAction()
        XCTAssertNotNil(notice)
        XCTAssertNil(await journal.consumeRecoveryAction())
    }

    func testLegacyUnversionedArrayIsMigrated() async throws {
        let legacy = try JSONEncoder().encode([event(1), event(2)])
        let state = OSAllocatedUnfairLock(initialState: MemoryState(data: legacy))
        let journal = DiagnosticEventJournal(io: memoryIO(state))
        let all = await journal.all()
        XCTAssertEqual(all.count, 2)
        let notice = await journal.consumeRecoveryAction()
        XCTAssertTrue(notice?.contains("Migrated") == true)
        let stored = try XCTUnwrap(state.withLock { $0.data })
        let migrated = try JSONDecoder().decode(FilteredPayload.self, from: stored)
        XCTAssertEqual(migrated.schemaVersion, 1)
        XCTAssertEqual(migrated.events.count, 2)
    }

    func testFilteredExportExcludesOtherCategories() async throws {
        let state = OSAllocatedUnfairLock(initialState: MemoryState())
        let journal = DiagnosticEventJournal(io: memoryIO(state))
        await journal.record(event(1))
        await journal.record(.make(
            code: DiagnosticEventCode.networkFailure,
            severity: .error,
            category: .network,
            userMessage: "Network failed"
        ))

        let filter = DiagnosticExportFilter(categories: [.network])
        let data = await journal.exportJSON(filter: filter)
        let decoded = try JSONDecoder().decode(FilteredPayload.self, from: data)
        XCTAssertEqual(decoded.events.count, 1)
        XCTAssertEqual(decoded.events.first?.category, .network)
    }

    private struct FilteredPayload: Decodable {
        let schemaVersion: Int
        let events: [DiagnosticEvent]
    }
}
