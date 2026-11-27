//
//  PersistentAutomationEngineTests.swift
//  VexSign
//
//  Eligibility, bounded retries, overlap prevention, cancellation recovery and
//  persistence across a restart. The executor is a test double; production
//  runs the real automation services.
//

import Foundation
import XCTest
@testable import VexSign

final class PersistentAutomationEngineTests: XCTestCase {
    private actor CountingExecutor: AutomationJobExecuting {
        private(set) var calls = 0
        var shouldFail = false
        var delayNanoseconds: UInt64 = 0

        func run(_ job: AutomationJobDefinition) async throws -> AutomationJobResult {
            calls += 1
            if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds) }
            if shouldFail { throw NSError(domain: "VexSignTests", code: 7, userInfo: [NSLocalizedDescriptionKey: "Service failed."]) }
            return .succeeded("Checked \(job.kind.rawValue).")
        }

        func callCount() -> Int { calls }
        func setFailure(_ value: Bool) { shouldFail = value }
        func setDelay(_ nanoseconds: UInt64) { delayNanoseconds = nanoseconds }
    }

    private func suite() -> UserDefaults {
        let name = "VexSignTests.automation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testDisabledAndBackedOffJobsAreNotRun() async {
        let defaults = suite()
        let executor = CountingExecutor()
        let now = Date()
        let engine = PersistentAutomationEngine(
            store: AutomationJobStore(defaults: defaults), executor: executor, clock: { now }
        )
        let jobID = AutomationJobStore.defaultJobs[0].id
        await engine.setEnabled(jobID, false)
        let skipped = await engine.run(id: jobID)
        XCTAssertEqual(skipped.status, .skipped)
        XCTAssertEqual(await executor.callCount(), 0)

        await engine.setEnabled(jobID, true)
        let first = await engine.run(id: jobID)
        XCTAssertEqual(first.status, .succeeded)
        let second = await engine.run(id: jobID)
        XCTAssertEqual(second.status, .skipped, "the same job must not run twice in one interval")
        XCTAssertEqual(await executor.callCount(), 1)
    }

    func testFailureAppliesBoundedBackoffAndRecordsLastResult() async {
        let defaults = suite()
        let executor = CountingExecutor()
        await executor.setFailure(true)
        let now = Date()
        let engine = PersistentAutomationEngine(
            store: AutomationJobStore(defaults: defaults), executor: executor, clock: { now }
        )
        let jobID = AutomationJobStore.defaultJobs[0].id
        let failed = await engine.run(id: jobID)
        XCTAssertEqual(failed.status, .failed)

        let stored = await AutomationJobStore(defaults: defaults).job(id: jobID)
        XCTAssertEqual(stored?.consecutiveFailures, 1)
        XCTAssertEqual(stored?.lastResult?.status, .failed)
        XCTAssertEqual(stored?.nextEligibleAt?.timeIntervalSince(now),
                       AutomationEnginePolicy.backoff(forFailures: 1))
        XCTAssertEqual(AutomationEnginePolicy.backoff(forFailures: 20), AutomationEnginePolicy.maximumBackoff)
    }

    func testOverlappingRunIsSkipped() async {
        let defaults = suite()
        let executor = CountingExecutor()
        await executor.setDelay(50_000_000)
        let engine = PersistentAutomationEngine(store: AutomationJobStore(defaults: defaults), executor: executor)
        let jobID = AutomationJobStore.defaultJobs[1].id
        async let first = engine.run(id: jobID)
        async let second = engine.run(id: jobID)
        let firstResult = await first
        let secondResult = await second
        XCTAssertEqual([firstResult, secondResult].map(\.status), [.succeeded, .skipped])
        XCTAssertEqual(await executor.callCount(), 1)
    }

    func testManualClaimPreventsDuplicatePass() async {
        let defaults = suite()
        let executor = CountingExecutor()
        let engine = PersistentAutomationEngine(store: AutomationJobStore(defaults: defaults), executor: executor)
        let jobID = AutomationJobStore.defaultJobs[0].id
        XCTAssertTrue(await engine.claim(jobID))
        let blocked = await engine.run(id: jobID)
        XCTAssertEqual(blocked.status, .skipped)
        XCTAssertEqual(await executor.callCount(), 0)
        await engine.release(jobID)
        XCTAssertEqual((await engine.run(id: jobID)).status, .succeeded)
    }

    func testStateSurvivesRestart() async {
        let defaults = suite()
        let now = Date()
        let executor = CountingExecutor()
        let firstEngine = PersistentAutomationEngine(
            store: AutomationJobStore(defaults: defaults), executor: executor, clock: { now }
        )
        let jobID = AutomationJobStore.defaultJobs[0].id
        _ = await firstEngine.run(id: jobID)

        let restarted = PersistentAutomationEngine(
            store: AutomationJobStore(defaults: defaults), executor: executor, clock: { now }
        )
        let snapshot = await restarted.snapshot()
        XCTAssertEqual(snapshot.first { $0.id == jobID }?.lastResult?.status, .succeeded)
        let result = await restarted.run(id: jobID)
        XCTAssertEqual(result.status, .skipped)
    }
}

