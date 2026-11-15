// The executor is internal, so the focused Apple host package tests its actual
// production source without exposing native pointer/admission APIs to the app.
#if canImport(DeviceFoundation)
import Foundation
import XCTest
@testable import DeviceFoundation

final class DeviceOperationExecutorTests: XCTestCase {
    func testTheCompleteOperationRunsOffMainAndReleasesItsSlotBeforeReturning() async throws {
        let executor = DeviceOperationExecutor()
        let result = try await executor.run(waiterTimeout: 1) { _ in
            XCTAssertFalse(Thread.isMainThread)
            return 42
        }
        XCTAssertEqual(result, 42)
        XCTAssertFalse(executor.isBusy)
    }

    func testTimeoutAbandonsOnlyTheWaiterAndRefusesAnotherOperationUntilRetirement() async throws {
        let executor = DeviceOperationExecutor()
        let entered = expectation(description: "native worker entered")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let first = Task {
            try await executor.run(waiterTimeout: 0.1) { _ in
                entered.fulfill()
                _ = release.wait(timeout: .now() + 3)
                return 1
            }
        }
        await fulfillment(of: [entered], timeout: 1)
        do { _ = try await first.value; XCTFail("A held worker cannot have completed") }
        catch { XCTAssertEqual(error as? DeviceTransportError, .operationTimedOut) }
        XCTAssertTrue(executor.isBusy)
        do {
            _ = try await executor.run(waiterTimeout: 0.1) { _ in XCTFail("Must not overlap a retiring worker"); return 2 }
            XCTFail("A second operation was admitted")
        } catch { XCTAssertEqual(error as? DeviceTransportError, .operationBusy) }
        release.signal()
        try await requireRetirement(executor)
        let next = try await executor.run(waiterTimeout: 1) { _ in 3 }
        XCTAssertEqual(next, 3)
    }

    func testCancellationNeverFreesAnActiveNativeOperation() async throws {
        let executor = DeviceOperationExecutor()
        let entered = expectation(description: "worker entered")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let first = Task {
            try await executor.run(waiterTimeout: 2) { _ in
                entered.fulfill()
                _ = release.wait(timeout: .now() + 3)
                return 1
            }
        }
        await fulfillment(of: [entered], timeout: 1)
        first.cancel()
        do { _ = try await first.value; XCTFail("A cancelled query cannot authorize") }
        catch { XCTAssertEqual(error as? DeviceTransportError, .operationCancelled) }
        XCTAssertTrue(executor.isBusy, "The worker still owns every native handle")
        release.signal()
        try await requireRetirement(executor)
    }

    func testAlreadyCancelledTasksDoNotAdmitOrMutate() async {
        let executor = DeviceOperationExecutor()
        let attempt = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await executor.run(waiterTimeout: 1) { _ in
                XCTFail("Pre-cancelled work must never enter")
                return 1
            }
        }
        do { _ = try await attempt.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(executor.isBusy)
    }

    func testProtectedFileCommitReturnsItsActualResultWhenCancellationRacesTheCommit() async throws {
        let executor = DeviceOperationExecutor()
        let entered = expectation(description: "commit entered")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let commit = Task {
            try await executor.run { _ in
                entered.fulfill()
                _ = release.wait(timeout: .now() + 3)
                return "committed" // models an indivisible rename, not a native/device success
            }
        }
        await fulfillment(of: [entered], timeout: 1)
        commit.cancel()
        XCTAssertTrue(executor.isBusy)
        release.signal()
        let result = try await commit.value
        XCTAssertEqual(result, "committed")
        XCTAssertFalse(executor.isBusy)
    }

    func testRepeatedCompletionTimerAndCancellationRacesDoNotResumeTwice() async throws {
        let executor = DeviceOperationExecutor()
        for _ in 0..<40 {
            let attempt = Task { try await executor.run(waiterTimeout: 0.01) { _ in 7 } }
            attempt.cancel()
            do { _ = try await attempt.value }
            catch {
                XCTAssertTrue(error is CancellationError || error as? DeviceTransportError == .operationCancelled)
            }
            try await requireRetirement(executor)
        }
        let finalResult = try await executor.run(waiterTimeout: 1) { _ in 9 }
        XCTAssertEqual(finalResult, 9)
    }

    private func requireRetirement(_ executor: DeviceOperationExecutor) async throws {
        // Bounded fixture synchronization, NOT how product callers should poll.
        // The synthetic worker also has its own 3-second release backstop.
        for _ in 0..<400 {
            if !executor.isBusy { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Worker failed to retire; never pretend the admission slot is free")
    }
}
#endif
