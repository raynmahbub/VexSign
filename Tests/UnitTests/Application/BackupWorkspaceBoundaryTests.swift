import Foundation
import XCTest
@testable import VexSign

@MainActor
final class BackupWorkspaceBoundaryTests: XCTestCase {
    // MARK: - Shared backup handoff

    /// A handed-over `.vexbackup` can only ever be an *offer*: staging must not
    /// restore, and a later file replaces the offer instead of queueing one.
    func testSharedBackupInboxStagesOneOfferAndClearsOnlyThatOffer() {
        let inbox = SharedBackupInbox()
        XCTAssertNil(inbox.staged, "Nothing is offered before a file arrives")

        let first = URL(fileURLWithPath: "/tmp/first.vexbackup")
        inbox.stage(first, now: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(inbox.staged?.url, first)
        XCTAssertEqual(inbox.staged?.receivedAt, Date(timeIntervalSince1970: 1_000))

        // A second handover replaces the first: two pending restores would ask the
        // user to approve something they never chose.
        let second = URL(fileURLWithPath: "/tmp/second.vexbackup")
        inbox.stage(second, now: Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(inbox.staged?.url, second)

        // Clearing with a stale identity must not dismiss the current offer.
        let stale = inbox.staged!
        inbox.stage(first)
        inbox.clear(stale.id)
        XCTAssertEqual(inbox.staged?.url, first, "A stale clear must not drop the current offer")

        let current = inbox.staged!
        inbox.clear(current.id)
        XCTAssertNil(inbox.staged)
    }

    private final class Provider: BackupWorkspaceProviding {
        var started: XCTestExpectation?
        var pending: CheckedContinuation<BackupArchiveSnapshot, Error>?
        var restoreStarted: XCTestExpectation?
        var pendingRestore: CheckedContinuation<BackupRestoreSummary, Error>?
        var opened = 0
        var made = 0
        var restored: [UUID] = []
        var released: [UUID] = []
        func availableComponents() -> BackupAvailability { BackupAvailability(components: [.settings], counts: [.settings: 1]) }
        func protection(of url: URL) async throws -> BackupImportProtection { .password }
        func makeBackup(password: String, components: BackupComponents) async throws -> URL {
            made += 1; return URL(fileURLWithPath: "/fixture/backup.vexsignbackup")
        }
        func open(_ url: URL, password: String) async throws -> BackupArchiveSnapshot {
            opened += 1
            return try await withCheckedThrowingContinuation { continuation in
                pending = continuation; started?.fulfill()
            }
        }
        func restore(archiveID: UUID, components: BackupComponents) async throws -> BackupRestoreSummary {
            restored.append(archiveID)
            guard let restoreStarted else { return BackupRestoreSummary() }
            return try await withCheckedThrowingContinuation { continuation in
                pendingRestore = continuation; restoreStarted.fulfill()
            }
        }
        func release(archiveID: UUID) { released.append(archiveID) }
        func complete(_ preview: BackupArchiveSnapshot) { pending?.resume(returning: preview); pending = nil }
        func completeRestore(_ summary: BackupRestoreSummary) { pendingRestore?.resume(returning: summary); pendingRestore = nil }
    }

    func testOverlappingOpenAndExportAreRefusedUntilTheOwnerCompletes() async throws {
        let provider = Provider()
        let started = expectation(description: "first open owns the adapter")
        provider.started = started
        let useCase = BackupWorkspaceUseCase(provider: provider)
        let first = Task { @MainActor in try await useCase.open(URL(fileURLWithPath: "/fixture/input"), password: "fixture") }
        await fulfillment(of: [started], timeout: 2)
        do {
            _ = try await useCase.makeBackup(password: "fixture", components: [.settings])
            XCTFail("Concurrent work should be refused")
        } catch { XCTAssertEqual(error as? ArchitectureDomainError, .duplicateOrBusyOperation) }
        XCTAssertEqual(provider.made, 0)
        let preview = FeatureBoundaryFixtures.backup()
        provider.complete(preview)
        let opened = try await first.value
        XCTAssertEqual(opened.id, preview.id)
        _ = try await useCase.makeBackup(password: "fixture", components: [.settings])
        XCTAssertEqual(provider.made, 1)
    }

    func testCancellationAfterOpaquePreviewCreationReleasesIt() async {
        let provider = Provider()
        let started = expectation(description: "open suspended")
        provider.started = started
        let useCase = BackupWorkspaceUseCase(provider: provider)
        let operation = Task { @MainActor in try await useCase.open(URL(fileURLWithPath: "/fixture/input"), password: "fixture") }
        await fulfillment(of: [started], timeout: 2)
        operation.cancel()
        let preview = FeatureBoundaryFixtures.backup()
        provider.complete(preview)
        do { _ = try await operation.value; XCTFail("Cancelled preview must not be published") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(provider.released, [preview.id])
        XCTAssertTrue(provider.restored.isEmpty)
    }

    func testRestoreCannotRequestAnEmptyOrUnlistedComponent() async {
        let provider = Provider()
        let useCase = BackupWorkspaceUseCase(provider: provider)
        let preview = FeatureBoundaryFixtures.backup()
        let selections: [BackupComponents] = [[], [.certificates], [.settings, .library]]
        for selection in selections {
            do { _ = try await useCase.restore(preview, components: selection); XCTFail("Invalid selection") }
            catch { XCTAssertEqual(error as? WorkspaceAccessError, .invalidReference) }
        }
        XCTAssertTrue(provider.restored.isEmpty)
    }

    func testRestoreForwardsOnlyTheOpaqueIdentityAndAllowedSelection() async throws {
        let provider = Provider()
        let useCase = BackupWorkspaceUseCase(provider: provider)
        let preview = FeatureBoundaryFixtures.backup()
        _ = try await useCase.restore(preview, components: [.settings])
        XCTAssertEqual(provider.restored, [preview.id])
        useCase.release(archiveID: preview.id)
        XCTAssertEqual(provider.released, [preview.id])
    }

    private func summary(added: Int = 1) -> BackupRestoreSummary {
        var summary = BackupRestoreSummary()
        summary.record(.settings, added: added, skipped: 0)
        summary.recordVerification(.settings, verified: added)
        return summary
    }

    func testPresentationAdmitsCallbacksOnlyWhileVisible() throws {
        var presentation = BackupPresentationState()
        XCTAssertNil(presentation.beginOperation())
        XCTAssertFalse(presentation.isCurrent(UUID()))
        presentation.appear()
        let attempt = try XCTUnwrap(presentation.beginOperation())
        XCTAssertTrue(presentation.isCurrent(attempt))
        presentation.appear() // Duplicate appearance must not retire live work.
        XCTAssertTrue(presentation.isCurrent(attempt))
        presentation.disappear()
        XCTAssertNil(presentation.beginOperation())
        XCTAssertFalse(presentation.completeRestore(summary(), for: attempt))
        XCTAssertNil(presentation.takeRestoreCompletion())
    }

    func testDisappearanceAndReappearanceRetireDelayedCompletion() throws {
        var presentation = BackupPresentationState()
        presentation.appear()
        let attempt = try XCTUnwrap(presentation.beginOperation())
        XCTAssertTrue(presentation.completeRestore(summary(), for: attempt))
        presentation.disappear() // The delayed alert has not fired yet.
        XCTAssertNil(presentation.takeRestoreCompletion())
        presentation.appear()
        XCTAssertFalse(presentation.isCurrent(attempt))
        XCTAssertFalse(presentation.completeRestore(summary(), for: attempt))
        XCTAssertNil(presentation.takeRestoreCompletion())
        let replacement = try XCTUnwrap(presentation.beginOperation())
        XCTAssertTrue(presentation.completeRestore(summary(), for: replacement))
        XCTAssertEqual(presentation.takeRestoreCompletion()?.generation, replacement)
    }

    func testNewOperationDiscardsAnUnpresentedRestoreCompletion() throws {
        var presentation = BackupPresentationState()
        presentation.appear()
        let attempt = try XCTUnwrap(presentation.beginOperation())
        XCTAssertTrue(presentation.completeRestore(summary(), for: attempt))
        let replacement = try XCTUnwrap(presentation.beginOperation())
        XCTAssertNotEqual(attempt, replacement)
        XCTAssertFalse(presentation.isCurrent(attempt))
        XCTAssertNil(presentation.takeRestoreCompletion())
        XCTAssertFalse(presentation.completeRestore(summary(), for: attempt))
        XCTAssertTrue(presentation.isCurrent(replacement))
    }

    func testSheetDismissalAndDelayConsumeTheSummaryOnlyOnce() throws {
        var presentation = BackupPresentationState()
        presentation.appear()
        let attempt = try XCTUnwrap(presentation.beginOperation())
        XCTAssertTrue(presentation.completeRestore(summary(added: 3), for: attempt))
        let completion = try XCTUnwrap(presentation.takeRestoreCompletion())
        XCTAssertEqual(completion.generation, attempt)
        XCTAssertEqual(completion.summary.counts(for: .settings).added, 3)
        XCTAssertEqual(completion.summary.unverified, 0)
        XCTAssertNil(presentation.takeRestoreCompletion(), "The other presentation path must not show a second alert")
        XCTAssertFalse(presentation.completeRestore(summary(added: 4), for: attempt))
        XCTAssertNil(presentation.takeRestoreCompletion(), "A repeated result cannot re-arm the consumed offer")
    }

    func testStaleCompletionCannotOverwriteTheCurrentSummary() throws {
        var presentation = BackupPresentationState()
        presentation.appear()
        let old = try XCTUnwrap(presentation.beginOperation())
        let current = try XCTUnwrap(presentation.beginOperation())
        XCTAssertTrue(presentation.completeRestore(summary(added: 2), for: current))
        XCTAssertFalse(presentation.completeRestore(summary(added: 99), for: old))
        let completion = try XCTUnwrap(presentation.takeRestoreCompletion())
        XCTAssertEqual(completion.generation, current)
        XCTAssertEqual(completion.summary.counts(for: .settings).added, 2)
    }

    func testConsumedRestartPermissionExpiresWithItsOperation() throws {
        var presentation = BackupPresentationState()
        presentation.appear()
        let attempt = try XCTUnwrap(presentation.beginOperation())
        XCTAssertTrue(presentation.completeRestore(summary(), for: attempt))
        let completion = try XCTUnwrap(presentation.takeRestoreCompletion())
        XCTAssertTrue(presentation.isCurrent(completion.generation))
        _ = presentation.beginOperation()
        XCTAssertFalse(presentation.isCurrent(completion.generation))
        presentation.disappear()
        presentation.appear()
        XCTAssertFalse(presentation.isCurrent(completion.generation), "A retained Restart action must not affect another appearance")
    }

    func testLateRestoreResultAfterCancellationDoesNotInventRollback() async throws {
        let provider = Provider()
        let started = expectation(description: "restore suspended after admission")
        provider.restoreStarted = started
        let useCase = BackupWorkspaceUseCase(provider: provider)
        let preview = FeatureBoundaryFixtures.backup()
        var presentation = BackupPresentationState()
        presentation.appear()
        let attempt = try XCTUnwrap(presentation.beginOperation())
        let operation = Task { @MainActor in try await useCase.restore(preview, components: [.settings]) }
        await fulfillment(of: [started], timeout: 2)
        presentation.disappear()
        operation.cancel()
        // Model the existing owner's possible commit before cancellation is
        // observed. The UI may retire the result, but cannot erase that commit.
        provider.completeRestore(summary(added: 5))
        let committed = try await operation.value
        XCTAssertEqual(committed.counts(for: .settings).added, 5)
        XCTAssertEqual(committed.unverified, 0)
        XCTAssertFalse(presentation.completeRestore(committed, for: attempt))
        XCTAssertNil(presentation.takeRestoreCompletion())
        XCTAssertEqual(provider.restored, [preview.id])
        useCase.release(archiveID: preview.id)
        XCTAssertEqual(provider.released, [preview.id])
    }
}
