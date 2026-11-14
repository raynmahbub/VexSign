import Foundation
import Combine
import XCTest
@testable import VexSign

@MainActor
final class WorkspaceObservationAndUndoTests: XCTestCase {
    private enum ReadFailure: Error { case unavailable }
    private final class Catalog: WorkspaceCatalogProviding {
        var value = WorkspaceSnapshot(importedApps: [FeatureBoundaryFixtures.app()])
        var failure: Error?
        var terminated: XCTestExpectation?
        func readWorkspace() throws -> WorkspaceSnapshot { if let failure { throw failure }; return value }
        func workspaceChanges() -> AsyncStream<Void> {
            let terminated = terminated
            return AsyncStream { continuation in continuation.onTermination = { _ in terminated?.fulfill() } }
        }
    }

    func testFailedRefreshKeepsTheLastGoodSnapshotInsteadOfInventingAnEmptyStore() {
        let provider = Catalog()
        let model = WorkspaceViewModel(useCase: WorkspaceCatalogUseCase(repository: provider))
        let before = model.snapshot.importedApps
        let revision = model.revision
        provider.failure = ReadFailure.unavailable
        model.refresh()
        XCTAssertEqual(model.snapshot.importedApps, before)
        XCTAssertEqual(model.revision, revision)
        XCTAssertNotNil(model.loadError)
        provider.failure = nil
        model.refresh()
        XCTAssertNil(model.loadError)
    }

    func testDiscardedModelTerminatesItsObservationWithoutRetainingItself() async {
        let provider = Catalog()
        let terminated = expectation(description: "stream consumer terminated")
        provider.terminated = terminated
        var model: WorkspaceViewModel? = WorkspaceViewModel(useCase: WorkspaceCatalogUseCase(repository: provider))
        let wasReleased = { [weak model] in model == nil }
        model = nil
        XCTAssertTrue(wasReleased(), "The stream consumer must not retain its discarded model")
        await fulfillment(of: [terminated], timeout: 2)
    }

    func testObservationCancellationIsOnceAndRunsCallbacksOutsideTheLock() {
        var count = 0
        var owner: StreamObservationCancellation?
        let subscription = AnyCancellable { count += 1; owner?.cancel() }
        owner = StreamObservationCancellation(subscription)
        owner?.cancel()
        owner?.cancel()
        XCTAssertEqual(count, 1, "Re-entrant cancellation must neither deadlock nor repeat")
        owner = nil
        XCTAssertEqual(count, 1)
    }

    func testRetainingAStaleUndoTokenDoesNotRetainItsExpiredCaptures() {
        weak var captured: NSObject?
        var discarded = 0
        var restored = 0
        let removal: UndoableRemoval = {
            let object = NSObject()
            captured = object
            return UndoableRemoval(title: "Fixture", restore: {
                withExtendedLifetime(object) {}
                restored += 1; return true
            }, discard: {
                withExtendedLifetime(object) {}
                discarded += 1
            }, lifetime: .zero)
        }()
        XCTAssertNotNil(captured)
        UndoableRemoval.announce(removal)
        XCTAssertFalse(UndoableRemoval.undo(removal))
        XCTAssertEqual(discarded, 1)
        XCTAssertEqual(restored, 0)
        XCTAssertNil(captured, "The display value must not keep secret-capturing closures past the deadline")
        XCTAssertFalse(UndoableRemoval.undo(removal))
        XCTAssertEqual(discarded, 1)
    }

    func testCopiesOfAnUndoTokenCannotRestoreTwice() {
        var restored = 0
        var discarded = 0
        let removal = UndoableRemoval(title: "Fixture", restore: { restored += 1; return true }, discard: { discarded += 1 })
        let staleCopy = removal
        UndoableRemoval.announce(removal)
        XCTAssertTrue(UndoableRemoval.undo(removal))
        XCTAssertFalse(UndoableRemoval.undo(staleCopy))
        XCTAssertEqual(restored, 1)
        XCTAssertEqual(discarded, 0)
    }
}
