import Foundation
import XCTest
import os
@testable import VexSign

@MainActor
final class AppleAccountSessionRepositoryTests: XCTestCase {
    private enum Failure: Error, Equatable { case write, read, insert, delete }
    private struct Store: AppleAccountRecoverableSessionStorage, AppleAccountResumeJournalStorage {
        struct State: Sendable {
            var journal: AppleAccountResumeJournal?
            var items: [UUID: Data] = [:]
            var writes = 0
            var inserts = 0
            var deleted: [UUID] = []
            var failedWrites: Set<Int> = []
            var failRead = false
            var failInsert = false
            var failDelete = false
        }
        private let lock = OSAllocatedUnfairLock(initialState: State())
        var state: State { lock.withLock { $0 } }
        func configure(_ body: (inout State) -> Void) { lock.withLockUnchecked { body(&$0) } }
        func readJournal() throws -> AppleAccountResumeJournal? {
            try lock.withLock {
                if $0.failRead { throw Failure.read }
                return $0.journal
            }
        }
        func writeJournal(_ journal: AppleAccountResumeJournal) throws {
            try journal.validate()
            try lock.withLock {
                $0.writes += 1
                if $0.failedWrites.contains($0.writes) { throw Failure.write }
                $0.journal = journal
            }
        }
        func insertSession(_ sessionData: Data, reference: UUID) throws -> UUID {
            try lock.withLock {
                $0.inserts += 1
                if $0.failInsert { throw Failure.insert }
                precondition($0.items[reference] == nil)
                $0.items[reference] = sessionData
                return reference
            }
        }
        func readSession(reference: UUID) throws -> Data? { lock.withLock { $0.items[reference] } }
        func deleteSession(reference: UUID) throws {
            try lock.withLock {
                if $0.failDelete { throw Failure.delete }
                $0.deleted.append(reference)
                $0.items.removeValue(forKey: reference)
            }
        }
    }

    private let data = Data([1, 2, 3])
    private func repository(_ store: Store) -> AppleAccountSessionRepository<Store, Store> {
        AppleAccountSessionRepository(sessions: store, journal: store)
    }

    func testCommitSurvivesRecreationAsUnvalidatedCandidateWithTeamHint() async throws {
        let store = Store()
        let first = repository(store)
        let reference = try await first.commitNewSession(data)
        try await first.saveSelectedTeamHint("TEAM", reference: reference)
        let candidate = try await repository(store).recoverCandidate()
        XCTAssertEqual(candidate?.reference, reference)
        XCTAssertEqual(candidate?.encodedSession, data)
        XCTAssertEqual(candidate?.selectedTeamHint, "TEAM")
        XCTAssertNil(store.state.journal?.pendingInsert)
        do {
            _ = try await first.commitNewSession(data)
            XCTFail("Cannot replace an accepted session")
        } catch { XCTAssertEqual(error as? AppleAccountSessionRepositoryError, .sessionAlreadySelected) }
        do {
            try await first.saveSelectedTeamHint("OTHER", reference: UUID())
            XCTFail("A stale reference must not change the hint")
        } catch { XCTAssertEqual(error as? AppleAccountSessionRepositoryError, .staleReference) }
        XCTAssertEqual(store.state.journal?.selectedTeamIdentifier, "TEAM")
    }

    func testFailedReservationNeverWritesSession() async throws {
        let store = Store()
        store.configure { $0.failedWrites = [1] }
        do {
            _ = try await repository(store).commitNewSession(data)
            XCTFail("Reservation error must propagate")
        } catch { XCTAssertEqual(error as? Failure, .write) }
        XCTAssertEqual(store.state.inserts, 0)
        XCTAssertTrue(store.state.items.isEmpty)
        XCTAssertNil(store.state.journal)
    }

    func testFailedSelectionCommitLeavesTrackedOrphanRecoveredAfterRestart() async throws {
        let store = Store()
        store.configure { $0.failedWrites = [2] }
        do {
            _ = try await repository(store).commitNewSession(data)
            XCTFail("Final write error must propagate")
        } catch { XCTAssertEqual(error as? Failure, .write) }
        let pending = try XCTUnwrap(store.state.journal?.pendingInsert)
        XCTAssertEqual(store.state.items[pending], data)
        let candidate = try await repository(store).recoverCandidate()
        XCTAssertNil(candidate)
        XCTAssertTrue(store.state.items.isEmpty)
        XCTAssertEqual(store.state.deleted, [pending])
        XCTAssertNil(store.state.journal?.pendingInsert)
    }

    func testFailedInsertReservationIsRecoverableAndDoesNotBecomeSelected() async throws {
        let store = Store()
        store.configure { $0.failInsert = true }
        do {
            _ = try await repository(store).commitNewSession(data)
            XCTFail("Insert error must propagate")
        } catch { XCTAssertEqual(error as? Failure, .insert) }
        XCTAssertNotNil(store.state.journal?.pendingInsert)
        XCTAssertNil(store.state.journal?.selectedReference)
        let candidate = try await repository(store).recoverCandidate()
        XCTAssertNil(candidate)
        XCTAssertNil(store.state.journal?.pendingInsert)
    }

    func testPersistedSignOutIntentRetriesFailedDeletionAcrossRestart() async throws {
        let store = Store()
        let first = repository(store)
        let reference = try await first.commitNewSession(data)
        store.configure { $0.failDelete = true }
        do {
            try await first.signOut()
            XCTFail("Deletion error must propagate")
        } catch { XCTAssertEqual(error as? Failure, .delete) }
        XCTAssertNil(store.state.journal?.selectedReference)
        XCTAssertEqual(store.state.journal?.pendingDeletions, [reference])
        XCTAssertEqual(store.state.items[reference], data)
        store.configure { $0.failDelete = false }
        let candidate = try await repository(store).recoverCandidate()
        XCTAssertNil(candidate)
        XCTAssertTrue(store.state.items.isEmpty)
        XCTAssertTrue(store.state.journal?.pendingDeletions.isEmpty == true)
    }

    func testFailedInitialSignOutWriteIsNotClaimedDurableAndBlocksSameInstance() async throws {
        let store = Store()
        let first = repository(store)
        let reference = try await first.commitNewSession(data)
        store.configure { $0.failedWrites = [3] }
        do {
            try await first.signOut()
            XCTFail("Initial intent was not persisted")
        } catch { XCTAssertEqual(error as? Failure, .write) }
        XCTAssertTrue(store.state.deleted.isEmpty)
        do {
            _ = try await first.recoverCandidate()
            XCTFail("In-process sign-out request must block restoration")
        } catch { XCTAssertEqual(error as? AppleAccountSessionRepositoryError, .signOutIncomplete) }
        // Disk still holds the old selection: never promise durable sign-out if
        // even the intent write failed (e.g. device locked or Keychain denied).
        let afterRestart = try await repository(store).recoverCandidate()
        XCTAssertEqual(afterRestart?.reference, reference)
        try await first.signOut()
        XCTAssertTrue(store.state.items.isEmpty)
    }

    func testDeletionBeforeFailedJournalRewriteIsIdempotentlyRecovered() async throws {
        let store = Store()
        let first = repository(store)
        let reference = try await first.commitNewSession(data)
        store.configure { $0.failedWrites = [4] }
        do {
            try await first.signOut()
            XCTFail("Cleanup rewrite error must propagate")
        } catch { XCTAssertEqual(error as? Failure, .write) }
        XCTAssertTrue(store.state.items.isEmpty)
        XCTAssertEqual(store.state.journal?.pendingDeletions, [reference])
        let candidate = try await repository(store).recoverCandidate()
        XCTAssertNil(candidate)
        XCTAssertEqual(store.state.deleted, [reference, reference])
    }

    func testInaccessibleJournalNeverBecomesEmptyOrOverwritesSelection() async throws {
        let store = Store()
        store.configure { $0.failRead = true }
        do {
            _ = try await repository(store).commitNewSession(data)
            XCTFail("Read failure must not mean empty journal")
        } catch { XCTAssertEqual(error as? Failure, .read) }
        XCTAssertEqual(store.state.writes, 0)
        XCTAssertEqual(store.state.inserts, 0)
    }

    func testMissingSelectedSessionRequiresExplicitCleanup() async throws {
        let store = Store()
        let first = repository(store)
        let reference = try await first.commitNewSession(data)
        store.configure { $0.items.removeValue(forKey: reference) }
        do {
            _ = try await repository(store).recoverCandidate()
            XCTFail("Dangling selection must not silently disappear")
        } catch { XCTAssertEqual(error as? AppleAccountSessionRepositoryError, .missingSelectedSession) }
        XCTAssertEqual(store.state.journal?.selectedReference, reference)
        try await first.signOut()
        XCTAssertNil(store.state.journal?.selectedReference)
    }

    func testInvalidOrUnsupportedJournalNeverTriggersDeletion() async throws {
        for unsupported in [false, true] {
            let store = Store()
            let reference = UUID()
            var journal = AppleAccountResumeJournal()
            journal.selectedReference = reference
            if unsupported { journal.schema = 2 } else { journal.pendingDeletions = [reference] }
            store.configure { $0.journal = journal; $0.items[reference] = data }
            do {
                _ = try await repository(store).recoverCandidate()
                XCTFail("Invalid journal must fail closed")
            } catch {
                XCTAssertEqual(error as? AppleAccountSessionRepositoryError,
                               unsupported ? .unsupportedJournalVersion : .invalidJournal)
            }
            XCTAssertTrue(store.state.deleted.isEmpty)
            XCTAssertEqual(store.state.writes, 0)
        }
    }
}
