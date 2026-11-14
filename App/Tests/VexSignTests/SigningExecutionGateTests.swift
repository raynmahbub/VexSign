import Foundation
import XCTest
@testable import VexSign

final class SigningExecutionGateTests: XCTestCase {
    private enum FixtureError: Error { case failed }

    private func waitForWaiters(_ count: Int, gate: SigningExecutionGate) async throws {
        for _ in 0..<250 {
            if await gate.waitingCount == count { return }
            try await Task.sleep(nanoseconds: 4_000_000)
        }
        throw FixtureError.failed
    }

    func testWaitersAcquireInFIFOOrder() async throws {
        let gate = SigningExecutionGate()
        try await gate.acquire()
        let second = Task { try await gate.acquire() }
        try await waitForWaiters(1, gate: gate)
        let third = Task { try await gate.acquire() }
        try await waitForWaiters(2, gate: gate)
        await gate.release()
        try await second.value
        let count = await gate.waitingCount
        XCTAssertEqual(count, 1)
        await gate.release()
        try await third.value
        await gate.release()
        let result = try await gate.withPermit { 42 }
        XCTAssertEqual(result, 42)
    }

    func testCancelledWaiterDoesNotRunOrBlockFollowingWork() async throws {
        let gate = SigningExecutionGate()
        try await gate.acquire()
        let pending = Task { try await gate.withPermit { XCTFail("Cancelled native operation ran") } }
        try await waitForWaiters(1, gate: gate)
        pending.cancel()
        do {
            try await pending.value
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        let count = await gate.waitingCount
        XCTAssertEqual(count, 0)
        await gate.release()
        let ran = try await gate.withPermit { true }
        XCTAssertTrue(ran)
    }

    func testThrowingOperationReleasesPermit() async throws {
        let gate = SigningExecutionGate()
        do {
            let _: Void = try await gate.withPermit { throw FixtureError.failed }
            XCTFail("Expected operation failure")
        } catch { XCTAssertTrue(error is FixtureError) }
        let ran = try await gate.withPermit { true }
        XCTAssertTrue(ran)
    }

    func testAlreadyCancelledTaskCannotEnterNativeOperation() async throws {
        let gate = SigningExecutionGate()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await gate.withPermit { XCTFail("Already cancelled operation ran") }
        }
        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        let ran = try await gate.withPermit { true }
        XCTAssertTrue(ran)
    }
}
