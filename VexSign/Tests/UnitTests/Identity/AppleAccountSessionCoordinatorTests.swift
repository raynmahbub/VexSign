import Foundation
import XCTest
import os
@testable import VexSign

@MainActor
final class AppleAccountSessionCoordinatorTests: XCTestCase {
    private enum Failure: Error, Equatable { case insert, delete, journal }

    /// Value copies share a checked-Sendable lock, not unchecked mutable state.
    private struct Store: AppleAccountRecoverableSessionStorage, AppleAccountResumeJournalStorage {
        struct Records: Sendable {
            var items: [UUID: Data] = [:]
            var journal: AppleAccountResumeJournal?
            var journalWrites = 0
            var failingWrite: Int?
            var insertCalls = 0
            var deleted: [UUID] = []
            var failInsert = false
            var failDelete = false
        }
        private let lock = OSAllocatedUnfairLock(initialState: Records())
        var records: Records { lock.withLock { $0 } }
        func failJournalWrite(_ number: Int?) { lock.withLock { $0.failingWrite = number } }
        func readJournal() throws -> AppleAccountResumeJournal? { lock.withLock { $0.journal } }
        func writeJournal(_ journal: AppleAccountResumeJournal) throws {
            try journal.validate()
            try lock.withLock {
                $0.journalWrites += 1
                if $0.journalWrites == $0.failingWrite { throw Failure.journal }
                $0.journal = journal
            }
        }
        func readSession(reference: UUID) throws -> Data? { lock.withLock { $0.items[reference] } }
        func failInsert(_ value: Bool) { lock.withLock { $0.failInsert = value } }
        func failDelete(_ value: Bool) { lock.withLock { $0.failDelete = value } }
        func insertSession(_ sessionData: Data, reference: UUID) throws -> UUID {
            try lock.withLock { state in
                state.insertCalls += 1
                if state.failInsert { throw Failure.insert }
                precondition(state.items[reference] == nil)
                state.items[reference] = sessionData
                return reference
            }
        }
        func deleteSession(reference: UUID) throws {
            try lock.withLock { state in
                if state.failDelete { throw Failure.delete }
                state.deleted.append(reference)
                state.items.removeValue(forKey: reference)
            }
        }
    }

    private let now = Date(timeIntervalSince1970: 10_000)
    private let teams: [AppleAccountSessionMetadata.Team] = [
        .init(identifier: "FREE", membership: .free),
        .init(identifier: "PAID", membership: .paid)
    ]

    private func receive(_ coordinator: AppleAccountSessionCoordinator<Store, Store>, operation: UUID) async throws -> Bool {
        try await coordinator.receiveAuthenticatedSession(
            operation: operation, encodedSession: Data([1, 2, 3]),
            teams: teams, expiresAt: now.addingTimeInterval(60), now: now
        )
    }

    func testStaleAndDuplicateCallbacksNeverWriteOrDeleteAcceptedRecord() async throws {
        let store = Store()
        let coordinator = AppleAccountSessionCoordinator(sessions: store, journal: store)
        let first = try await coordinator.beginAuthentication()
        let old = try XCTUnwrap(first)
        let second = try await coordinator.beginAuthentication()
        let current = try XCTUnwrap(second)
        let stale = try await receive(coordinator, operation: old)
        XCTAssertFalse(stale)
        XCTAssertEqual(store.records.insertCalls, 0)
        let accepted = try await receive(coordinator, operation: current)
        let duplicate = try await receive(coordinator, operation: current)
        XCTAssertTrue(accepted)
        XCTAssertFalse(duplicate)
        XCTAssertEqual(store.records.items.count, 1)
        XCTAssertEqual(store.records.insertCalls, 1)
        XCTAssertTrue(store.records.deleted.isEmpty)
        let context = await coordinator.currentContext(at: now)
        XCTAssertNil(context, "No automatic team choice")
    }

    func testSignOutRejectsLateSuccessWithoutPersistingIt() async throws {
        let store = Store()
        let coordinator = AppleAccountSessionCoordinator(sessions: store, journal: store)
        let started = try await coordinator.beginAuthentication()
        let operation = try XCTUnwrap(started)
        try await coordinator.signOut()
        let result = try await receive(coordinator, operation: operation)
        XCTAssertFalse(result)
        XCTAssertEqual(store.records.insertCalls, 0)
    }

    func testFailedDeletionRemainsVisibleAndBlocksNewLoginUntilRetry() async throws {
        let store = Store()
        let coordinator = AppleAccountSessionCoordinator(sessions: store, journal: store)
        let started = try await coordinator.beginAuthentication()
        _ = try await receive(coordinator, operation: XCTUnwrap(started))
        let reference = try XCTUnwrap(store.records.items.keys.first)
        store.failDelete(true)
        do {
            try await coordinator.signOut()
            XCTFail("Deletion error must propagate")
        } catch { XCTAssertEqual(error as? Failure, .delete) }
        let snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot.phase, .signedOut)
        XCTAssertTrue(snapshot.cleanupRequired)
        XCTAssertEqual(store.records.journal?.pendingDeletions, [reference])
        do {
            _ = try await coordinator.beginAuthentication()
            XCTFail("Retained credentials must not be hidden")
        } catch { XCTAssertEqual(error as? AppleAccountSessionCoordinatorError, .cleanupRequired) }
        store.failDelete(false)
        try await coordinator.retryPendingDeletions()
        XCTAssertEqual(store.records.deleted, [reference])
        XCTAssertTrue(store.records.items.isEmpty)
        let after = await coordinator.snapshot()
        XCTAssertFalse(after.cleanupRequired)
        let next = try await coordinator.beginAuthentication()
        XCTAssertNotNil(next)
    }

    func testInsertFailureDoesNotPublishSessionAndCanBeRetried() async throws {
        let store = Store()
        let coordinator = AppleAccountSessionCoordinator(sessions: store, journal: store)
        let started = try await coordinator.beginAuthentication()
        let operation = try XCTUnwrap(started)
        store.failInsert(true)
        do {
            _ = try await receive(coordinator, operation: operation)
            XCTFail("Insert error must propagate")
        } catch { XCTAssertEqual(error as? Failure, .insert) }
        let snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot.phase, .signedOut)
        XCTAssertTrue(snapshot.cleanupRequired)
        XCTAssertTrue(store.records.items.isEmpty)
        XCTAssertNotNil(store.records.journal?.pendingInsert)
        store.failInsert(false)
        try await coordinator.retryPendingDeletions()
        let retried = try await coordinator.beginAuthentication()
        let accepted = try await receive(coordinator, operation: XCTUnwrap(retried))
        XCTAssertTrue(accepted)
    }

    func testInvalidMetadataNeverReachesStorage() async throws {
        let store = Store()
        let coordinator = AppleAccountSessionCoordinator(sessions: store, journal: store)
        let started = try await coordinator.beginAuthentication()
        let operation = try XCTUnwrap(started)
        do {
            _ = try await coordinator.receiveAuthenticatedSession(
                operation: operation, encodedSession: Data([1]), teams: [], expiresAt: nil, now: now
            )
            XCTFail("Invalid metadata must fail before storage")
        } catch { XCTAssertEqual(error as? AppleAccountSessionCoordinatorError, .invalidSessionMetadata) }
        XCTAssertEqual(store.records.insertCalls, 0)
    }

    func testRetryCancelsTaskAndRejectsLateTaskRegistration() async throws {
        let store = Store()
        let coordinator = AppleAccountSessionCoordinator(sessions: store, journal: store)
        let started = try await coordinator.beginAuthentication()
        let old = try XCTUnwrap(started)
        let task = Task<Void, Never> { try? await Task.sleep(nanoseconds: 60_000_000_000) }
        let attached = await coordinator.attachAuthenticationTask(task, operation: old)
        XCTAssertTrue(attached)
        _ = try await coordinator.beginAuthentication()
        XCTAssertTrue(task.isCancelled)
        let lateTask = Task<Void, Never> { try? await Task.sleep(nanoseconds: 60_000_000_000) }
        let lateAttached = await coordinator.attachAuthenticationTask(lateTask, operation: old)
        XCTAssertFalse(lateAttached)
        XCTAssertTrue(lateTask.isCancelled)
        try await coordinator.signOut()
    }

    func testTeamChangeInvalidatesProvisioningContextAndSignOutDeletesOnlyOwnedRecord() async throws {
        let store = Store()
        let coordinator = AppleAccountSessionCoordinator(sessions: store, journal: store)
        let started = try await coordinator.beginAuthentication()
        let operation = try XCTUnwrap(started)
        _ = try await receive(coordinator, operation: operation)
        let chosen = try await coordinator.selectTeam(identifier: "FREE", operation: operation, now: now)
        XCTAssertTrue(chosen)
        let firstContext = await coordinator.currentContext(at: now)
        let first = try XCTUnwrap(firstContext)
        let changed = try await coordinator.changeTeam(identifier: "PAID", now: now)
        XCTAssertTrue(changed)
        let accepted = await coordinator.acceptsProvisioningResult(contextID: first.id, now: now)
        XCTAssertFalse(accepted)
        try await coordinator.signOut()
        XCTAssertEqual(store.records.deleted, [first.session.credentialReference])
        XCTAssertTrue(store.records.items.isEmpty)
    }

    func testStaleFailureDoesNotCancelCurrentTaskOrResetChallenge() async throws {
        let store = Store()
        let coordinator = AppleAccountSessionCoordinator(sessions: store, journal: store)
        let started = try await coordinator.beginAuthentication()
        let old = try XCTUnwrap(started)
        let retried = try await coordinator.beginAuthentication()
        let current = try XCTUnwrap(retried)
        let task = Task<Void, Never> { try? await Task.sleep(nanoseconds: 60_000_000_000) }
        _ = await coordinator.attachAuthenticationTask(task, operation: current)
        let challenged = await coordinator.requireTwoFactor(operation: current)
        XCTAssertTrue(challenged)
        let failed = await coordinator.failAuthentication(operation: old)
        XCTAssertFalse(failed)
        XCTAssertFalse(task.isCancelled)
        let snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot.phase, .awaitingTwoFactor(current))
        try await coordinator.signOut()
        XCTAssertTrue(task.isCancelled)
    }

    func testDurableSelectionPrecedesAcceptedSessionMetadata() async throws {
        let store = Store()
        let coordinator = AppleAccountSessionCoordinator(sessions: store, journal: store)
        let started = try await coordinator.beginAuthentication()
        let operation = try XCTUnwrap(started)
        _ = try await receive(coordinator, operation: operation)
        let snapshot = await coordinator.snapshot()
        guard case .awaitingTeamSelection(let current, let session) = snapshot.phase else {
            return XCTFail("A committed session still requires explicit team choice")
        }
        XCTAssertEqual(current, operation)
        XCTAssertEqual(store.records.journal?.selectedReference, session.credentialReference)
        XCTAssertNil(store.records.journal?.pendingInsert)
        XCTAssertNil(store.records.journal?.selectedTeamIdentifier)
    }

    func testFailedFinalCommitRequiresDurableCleanupBeforeRetry() async throws {
        let store = Store()
        let coordinator = AppleAccountSessionCoordinator(sessions: store, journal: store)
        let started = try await coordinator.beginAuthentication()
        let operation = try XCTUnwrap(started)
        store.failJournalWrite(2)
        do {
            _ = try await receive(coordinator, operation: operation)
            XCTFail("Failed final commit must not publish metadata")
        } catch { XCTAssertEqual(error as? Failure, .journal) }
        let snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot.phase, .signedOut)
        XCTAssertTrue(snapshot.cleanupRequired)
        let pending = try XCTUnwrap(store.records.journal?.pendingInsert)
        XCTAssertNotNil(store.records.items[pending])
        try await coordinator.retryPendingDeletions()
        XCTAssertEqual(store.records.deleted, [pending])
        XCTAssertNil(store.records.journal?.selectedReference)
        let late = try await receive(coordinator, operation: operation)
        XCTAssertFalse(late)
    }

    func testHintFailureDoesNotPublishTeamOrNewSigningContext() async throws {
        let store = Store()
        let coordinator = AppleAccountSessionCoordinator(sessions: store, journal: store)
        let started = try await coordinator.beginAuthentication()
        let operation = try XCTUnwrap(started)
        _ = try await receive(coordinator, operation: operation)
        store.failJournalWrite(3)
        do {
            _ = try await coordinator.selectTeam(identifier: "FREE", operation: operation, now: now)
            XCTFail("Failed hint write must not publish signed-in state")
        } catch { XCTAssertEqual(error as? Failure, .journal) }
        let noContext = await coordinator.currentContext(at: now)
        XCTAssertNil(noContext)
        XCTAssertNil(store.records.journal?.selectedTeamIdentifier)
        _ = try await coordinator.selectTeam(identifier: "FREE", operation: operation, now: now)
        let original = await coordinator.currentContext(at: now)
        let old = try XCTUnwrap(original)
        store.failJournalWrite(5)
        do {
            _ = try await coordinator.changeTeam(identifier: "PAID", now: now)
            XCTFail("Failed team change must preserve the old context")
        } catch { XCTAssertEqual(error as? Failure, .journal) }
        let retained = await coordinator.currentContext(at: now)
        XCTAssertEqual(retained, old)
        XCTAssertEqual(store.records.journal?.selectedTeamIdentifier, "FREE")
    }

    func testSavedCandidateBlocksFreshLoginWithoutAutomaticRestoration() async throws {
        let store = Store()
        let previous = AppleAccountSessionCoordinator(sessions: store, journal: store)
        let started = try await previous.beginAuthentication()
        _ = try await receive(previous, operation: XCTUnwrap(started))
        let restarted = AppleAccountSessionCoordinator(sessions: store, journal: store)
        do {
            _ = try await restarted.beginAuthentication()
            XCTFail("A saved account must not be silently replaced")
        } catch { XCTAssertEqual(error as? AppleAccountSessionCoordinatorError, .resumeRequired) }
        let candidate = try await restarted.recoverCandidate()
        XCTAssertEqual(candidate?.reference, store.records.journal?.selectedReference)
        let snapshot = await restarted.snapshot()
        XCTAssertEqual(snapshot.phase, .signedOut)
        XCTAssertEqual(store.records.insertCalls, 1)
    }

    func testFailedIntentInvalidatesContextButDoesNotClaimDurableSignOut() async throws {
        let store = Store()
        let coordinator = AppleAccountSessionCoordinator(sessions: store, journal: store)
        let started = try await coordinator.beginAuthentication()
        let operation = try XCTUnwrap(started)
        _ = try await receive(coordinator, operation: operation)
        _ = try await coordinator.selectTeam(identifier: "FREE", operation: operation, now: now)
        let context = await coordinator.currentContext(at: now)
        let previous = try XCTUnwrap(context)
        store.failJournalWrite(4)
        do {
            try await coordinator.signOut()
            XCTFail("Initial intent write failed")
        } catch { XCTAssertEqual(error as? Failure, .journal) }
        let accepted = await coordinator.acceptsProvisioningResult(contextID: previous.id, now: now)
        XCTAssertFalse(accepted)
        XCTAssertNotNil(store.records.journal?.selectedReference)
        do {
            _ = try await coordinator.recoverCandidate()
            XCTFail("Unfinished sign-out must block restoration")
        } catch { XCTAssertEqual(error as? AppleAccountSessionCoordinatorError, .cleanupRequired) }
        try await coordinator.retryPendingDeletions()
        XCTAssertTrue(store.records.items.isEmpty)
    }

    func testNewCoordinatorRecoversAnInterruptedReservationBeforeNewLogin() async throws {
        let store = Store()
        let previous = AppleAccountSessionCoordinator(sessions: store, journal: store)
        let started = try await previous.beginAuthentication()
        store.failJournalWrite(2)
        do {
            _ = try await receive(previous, operation: XCTUnwrap(started))
            XCTFail("Final selection write failed")
        } catch { XCTAssertEqual(error as? Failure, .journal) }
        let reference = try XCTUnwrap(store.records.journal?.pendingInsert)
        let restarted = AppleAccountSessionCoordinator(sessions: store, journal: store)
        let next = try await restarted.beginAuthentication()
        XCTAssertNotNil(next)
        XCTAssertTrue(store.records.items.isEmpty)
        XCTAssertEqual(store.records.deleted, [reference])
    }


    func testRevalidationPreservesReferenceAndRequiresNewTeamChoice() async throws {
        let store = Store()
        let previous = AppleAccountSessionCoordinator(sessions: store, journal: store)
        let started = try await previous.beginAuthentication()
        let originalOperation = try XCTUnwrap(started)
        _ = try await receive(previous, operation: originalOperation)
        _ = try await previous.selectTeam(identifier: "FREE", operation: originalOperation, now: now)
        let reference = try XCTUnwrap(store.records.journal?.selectedReference)
        let restarted = AppleAccountSessionCoordinator(sessions: store, journal: store)
        let resumed = try await restarted.beginRevalidation()
        let resume = try XCTUnwrap(resumed)
        let accepted = try await restarted.receiveRevalidatedSession(operation: resume.operation, reference: reference,
            teams: teams, expiresAt: now.addingTimeInterval(60), now: now)
        XCTAssertTrue(accepted)
        XCTAssertEqual(store.records.insertCalls, 1)
        let context = await restarted.currentContext(at: now)
        XCTAssertNil(context, "Saved team hint is not consent or authorization")
        let snapshot = await restarted.snapshot()
        guard case .awaitingTeamSelection(_, let metadata) = snapshot.phase else { return XCTFail("Expected team choice") }
        XCTAssertEqual(metadata.credentialReference, reference)
    }

    func testRevalidationRejectsStaleOperationAndWrongReferenceWithoutStorageWrites() async throws {
        let store = Store()
        let previous = AppleAccountSessionCoordinator(sessions: store, journal: store)
        let started = try await previous.beginAuthentication()
        _ = try await receive(previous, operation: XCTUnwrap(started))
        let restarted = AppleAccountSessionCoordinator(sessions: store, journal: store)
        let first = try await restarted.beginRevalidation()
        let old = try XCTUnwrap(first)
        let second = try await restarted.beginRevalidation()
        let current = try XCTUnwrap(second)
        let writes = store.records.journalWrites
        let stale = try await restarted.receiveRevalidatedSession(operation: old.operation, reference: old.candidate.reference,
            teams: teams, expiresAt: now.addingTimeInterval(60), now: now)
        let wrongReference = try await restarted.receiveRevalidatedSession(operation: current.operation, reference: UUID(),
            teams: teams, expiresAt: now.addingTimeInterval(60), now: now)
        let wrongAPI = try await receive(restarted, operation: current.operation)
        XCTAssertFalse(stale)
        XCTAssertFalse(wrongReference)
        XCTAssertFalse(wrongAPI)
        XCTAssertEqual(store.records.journalWrites, writes)
        XCTAssertEqual(store.records.insertCalls, 1)
    }

    func testRevalidationWithoutSavedRecordDoesNotCreateAnOperation() async throws {
        let store = Store()
        let coordinator = AppleAccountSessionCoordinator(sessions: store, journal: store)
        let candidate = try await coordinator.beginRevalidation()
        XCTAssertNil(candidate)
        let snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot.phase, .signedOut)
        XCTAssertEqual(store.records.insertCalls, 0)
    }

    func testSignOutRejectsLateRevalidationResult() async throws {
        let store = Store()
        let previous = AppleAccountSessionCoordinator(sessions: store, journal: store)
        let started = try await previous.beginAuthentication()
        _ = try await receive(previous, operation: XCTUnwrap(started))
        let restarted = AppleAccountSessionCoordinator(sessions: store, journal: store)
        let pending = try await restarted.beginRevalidation()
        let resume = try XCTUnwrap(pending)
        try await restarted.signOut()
        let accepted = try await restarted.receiveRevalidatedSession(operation: resume.operation, reference: resume.candidate.reference,
            teams: teams, expiresAt: now.addingTimeInterval(60), now: now)
        XCTAssertFalse(accepted)
        XCTAssertTrue(store.records.items.isEmpty)
    }

    func testUnverifiedDeveloperProgramCannotAuthorizeProvisioningResult() async throws {
        let store = Store()
        let coordinator = AppleAccountSessionCoordinator(sessions: store, journal: store)
        let started = try await coordinator.beginAuthentication()
        let operation = try XCTUnwrap(started)
        _ = try await coordinator.receiveAuthenticatedSession(operation: operation, encodedSession: Data([1]),
            teams: [.init(identifier: "ORG", membership: .developerProgramUnverified)], expiresAt: now.addingTimeInterval(60), now: now)
        _ = try await coordinator.selectTeam(identifier: "ORG", operation: operation, now: now)
        let current = await coordinator.currentContext(at: now)
        let context = try XCTUnwrap(current)
        let authorized = await coordinator.acceptsProvisioningResult(contextID: context.id, now: now)
        XCTAssertFalse(authorized)
    }

}
