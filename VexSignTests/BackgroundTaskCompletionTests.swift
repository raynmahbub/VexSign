// The background download lifecycle had two writers for one BGTask completion: the expiration
// handler called setTaskCompleted(success: false) and the monitoring worker called it again. These
// tests pin the rule that removed the race — exactly one completion, and expiration can neither be
// overwritten by a late worker nor overwrite a result that already landed.
import Foundation
import os
import XCTest
@testable import VexSign

final class BackgroundTaskCompletionTests: XCTestCase {

    // MARK: - Gate

    /// Records what reached `setTaskCompleted`. Locked, because the concurrent test calls it from
    /// several threads at once.
    private final class Recorder: Sendable {
        private let results = OSAllocatedUnfairLock<[Bool]>(initialState: [])

        var recorded: [Bool] { results.withLock { $0 } }

        func record(_ success: Bool) {
            results.withLock { $0.append(success) }
        }
    }

    func testWorkerCompletionCallsThroughOnce() {
        let recorder = Recorder()
        let gate = BackgroundTaskCompletionGate { recorder.record($0) }

        XCTAssertTrue(gate.finish(success: true))

        XCTAssertEqual(recorder.recorded, [true])
        XCTAssertEqual(gate.currentOutcome.success, true)
        XCTAssertEqual(gate.currentOutcome.source, .worker)
    }

    func testDuplicateWorkerCompletionIsDropped() {
        let recorder = Recorder()
        let gate = BackgroundTaskCompletionGate { recorder.record($0) }

        XCTAssertTrue(gate.finish(success: true))
        XCTAssertFalse(gate.finish(success: true))
        XCTAssertFalse(gate.finish(success: false))

        XCTAssertEqual(recorder.recorded, [true], "setTaskCompleted must be reached exactly once")
        XCTAssertEqual(gate.currentOutcome.ignoredCompletions, 2)
    }

    /// The failure this fix exists for: the system expires the task mid-download, the worker keeps
    /// going, and then reports success. Previously both reports reached the system.
    func testExpirationCannotBeOverwrittenByLateWorkerSuccess() {
        let recorder = Recorder()
        let gate = BackgroundTaskCompletionGate { recorder.record($0) }

        XCTAssertTrue(gate.expire())
        XCTAssertFalse(gate.finish(success: true), "a resulting late worker must not complete twice")

        XCTAssertEqual(recorder.recorded, [false])
        XCTAssertEqual(gate.currentOutcome.success, false)
        XCTAssertEqual(gate.currentOutcome.source, .expiration)
        XCTAssertTrue(gate.currentOutcome.expired)
    }

    /// The mirror image: work finished just before the system expired it. The success stands.
    func testWorkerSuccessSurvivesExpirationImmediatelyAfter() {
        let recorder = Recorder()
        let gate = BackgroundTaskCompletionGate { recorder.record($0) }

        XCTAssertTrue(gate.finish(success: true))
        XCTAssertFalse(gate.expire())

        XCTAssertEqual(recorder.recorded, [true])
        XCTAssertEqual(gate.currentOutcome.success, true)
    }

    func testExpireIsIdempotent() {
        let recorder = Recorder()
        let gate = BackgroundTaskCompletionGate { recorder.record($0) }

        XCTAssertTrue(gate.expire())
        XCTAssertFalse(gate.expire())

        XCTAssertEqual(recorder.recorded, [false])
    }

    /// Expiration can fire while `setTaskCompleted` is already on the stack. The lock must be
    /// released before calling out, or this deadlocks instead of failing.
    func testExpirationFromInsideCompletionDoesNotDeadlock() {
        let recorder = Recorder()
        var gate: BackgroundTaskCompletionGate!
        gate = BackgroundTaskCompletionGate { success in
            recorder.record(success)
            // Re-entrant call from another path while the first completion is in flight.
            gate.expire()
        }

        XCTAssertTrue(gate.finish(success: true))

        XCTAssertEqual(recorder.recorded, [true])
        XCTAssertEqual(gate.currentOutcome.ignoredCompletions, 0)
    }

    /// Concurrent completion from several threads must still produce one system call.
    func testConcurrentCompletionFromManyThreadsHasOneWinner() {
        let recorder = Recorder()
        let gate = BackgroundTaskCompletionGate { recorder.record($0) }
        let group = DispatchGroup()

        for index in 0..<32 {
            DispatchQueue.global().async(group: group) {
                gate.finish(success: index.isMultiple(of: 2))
            }
        }
        group.wait()

        XCTAssertEqual(recorder.recorded.count, 1)
        XCTAssertEqual(gate.currentOutcome.ignoredCompletions, 31)
    }

    // MARK: - Ownership handshake

    /// The main-actor hop from a `BGTaskScheduler` handler can be lost. If expiration arrives and
    /// no runner ever claimed ownership, nobody else will complete the task, so expiration must.
    func testExpirationCompletesWhenNoRunnerClaimedOwnership() {
        let recorder = Recorder()
        let gate = BackgroundTaskCompletionGate { recorder.record($0) }
        let ownership = BackgroundTaskOwnership(gate: gate)

        ownership.expired()

        XCTAssertEqual(recorder.recorded, [false])
        XCTAssertEqual(gate.currentOutcome.source, .expiration)
    }

    /// Once a runner claims ownership it reaches a `finish` on every path, so expiration must not
    /// complete the task on its behalf — that was the original double-completion bug.
    func testExpirationAfterRunnerClaimedDoesNotComplete() {
        let recorder = Recorder()
        let gate = BackgroundTaskCompletionGate { recorder.record($0) }
        let ownership = BackgroundTaskOwnership(gate: gate)

        ownership.runnerDidStart()
        ownership.expired()

        XCTAssertTrue(recorder.recorded.isEmpty, "the claimed runner owns the completion")
        XCTAssertFalse(gate.currentOutcome.isClosed)

        // The runner then closes it exactly once.
        gate.finish(success: false, source: .worker)
        XCTAssertEqual(recorder.recorded, [false])
    }

    func testRepeatedExpirationCompletesOnce() {
        let recorder = Recorder()
        let gate = BackgroundTaskCompletionGate { recorder.record($0) }
        let ownership = BackgroundTaskOwnership(gate: gate)

        ownership.expired()
        ownership.expired()
        ownership.expired()

        XCTAssertEqual(recorder.recorded, [false])
    }

    /// A runner that starts after an expiration already completed the task must not resurrect it.
    func testRunnerStartingAfterExpirationDoesNotCompleteAgain() {
        let recorder = Recorder()
        let gate = BackgroundTaskCompletionGate { recorder.record($0) }
        let ownership = BackgroundTaskOwnership(gate: gate)

        ownership.expired()
        ownership.runnerDidStart()
        gate.finish(success: true)

        XCTAssertEqual(recorder.recorded, [false])
    }

    /// Claim is exclusive, which is the whole mechanism.
    func testCompletionFlagClaimsExactlyOnce() {
        let flag = BackgroundWorkCompletionFlag()
        XCTAssertFalse(flag.isSet)
        XCTAssertTrue(flag.claim())
        XCTAssertTrue(flag.isSet)
        XCTAssertFalse(flag.claim())
    }

    // MARK: - Work sample

    func testIdleSampleReportsFinishedAtFullProgress() {
        let work = BackgroundDownloadWork.idle
        XCTAssertTrue(work.isFinished)
        XCTAssertEqual(work.completedPercent, 100)
    }

    func testProgressIsClampedAndAveraged() {
        let work = BackgroundDownloadWork(
            itemCount: 2,
            activeCount: 2,
            averageProgress: 0.42,
            hasUnfinishedWork: true
        )
        XCTAssertFalse(work.isFinished)
        XCTAssertEqual(work.completedPercent, 42)

        let over = BackgroundDownloadWork(
            itemCount: 2,
            activeCount: 1,
            averageProgress: 4.2,
            hasUnfinishedWork: true
        )
        XCTAssertEqual(over.completedPercent, 100, "a corrupt progress value must not overflow the counter")

        let under = BackgroundDownloadWork(
            itemCount: 1,
            activeCount: 1,
            averageProgress: -3,
            hasUnfinishedWork: true
        )
        XCTAssertEqual(under.completedPercent, 0)
    }

    /// Work left that is not a network transfer — verifying, importing, signing — still keeps the
    /// task alive, which is why `hasUnfinishedWork` is carried rather than inferred.
    func testNonTransferWorkIsNotFinished() {
        let work = BackgroundDownloadWork(
            itemCount: 1,
            activeCount: 0,
            averageProgress: 1,
            hasUnfinishedWork: true
        )
        XCTAssertFalse(work.isFinished)
        XCTAssertEqual(work.completedPercent, 99, "a running task must never show 100%")
    }

    // MARK: - Monitor policy

    func testIdleWinsAtTheDeadline() {
        let decision = BackgroundDownloadMonitorPolicy.decide(
            work: .idle,
            elapsed: 10,
            timeout: 10
        )
        XCTAssertEqual(decision, .finished, "a task that finished at the buzzer succeeded")
    }

    func testTimeoutReportsWhetherWorkWasLeftBehind() {
        let busy = BackgroundDownloadWork(
            itemCount: 1,
            activeCount: 1,
            averageProgress: 0.2,
            hasUnfinishedWork: true
        )
        XCTAssertEqual(
            BackgroundDownloadMonitorPolicy.decide(work: busy, elapsed: 600, timeout: 600),
            .timedOut(workRemaining: true)
        )

        let drained = BackgroundDownloadWork(
            itemCount: 1,
            activeCount: 0,
            averageProgress: 1,
            hasUnfinishedWork: false
        )
        XCTAssertEqual(
            BackgroundDownloadMonitorPolicy.decide(work: drained, elapsed: 600, timeout: 600),
            .timedOut(workRemaining: false)
        )
    }

    func testMonitoringContinuesWhileWorkRemainsInsideTheDeadline() {
        let busy = BackgroundDownloadWork(
            itemCount: 3,
            activeCount: 3,
            averageProgress: 0.5,
            hasUnfinishedWork: true
        )
        XCTAssertEqual(
            BackgroundDownloadMonitorPolicy.decide(work: busy, elapsed: 1, timeout: 600),
            .keepMonitoring
        )
    }

    // MARK: - Cancellation handle

    func testCancellationBeforeAdoptionIsRemembered() {
        let handle = BackgroundWorkCancellation()
        handle.cancel()

        XCTAssertTrue(handle.isCancelled)

        let task = Task { while !Task.isCancelled { await Task.yield() } }
        handle.adopt(task)
        XCTAssertTrue(task.isCancelled, "an expiration during launch must not leave an uncancellable loop")
        task.cancel()
    }

    func testCancellationAfterAdoptionCancelsTheTask() {
        let handle = BackgroundWorkCancellation()
        let task = Task { while !Task.isCancelled { await Task.yield() } }
        handle.adopt(task)
        handle.cancel()
        XCTAssertTrue(task.isCancelled)
    }

    // MARK: - Runner

    @MainActor
    private final class StubMonitor: BackgroundDownloadMonitoring {
        var samples: [BackgroundDownloadWork]
        var resumeCount = 0
        var pauseCount = 0
        private var index = 0

        init(samples: [BackgroundDownloadWork]) {
            self.samples = samples
        }

        func currentWork() -> BackgroundDownloadWork {
            defer { index += 1 }
            return samples[min(index, samples.count - 1)]
        }

        func resumeAll() { resumeCount += 1 }
        func pauseAll() { pauseCount += 1 }
    }

    private func busy(_ progress: Double) -> BackgroundDownloadWork {
        BackgroundDownloadWork(itemCount: 1, activeCount: 1, averageProgress: progress, hasUnfinishedWork: true)
    }

    @MainActor
    func testRunnerReportsSuccessAndResumesOnceWhenWorkDrains() async {
        let recorder = Recorder()
        let gate = BackgroundTaskCompletionGate { recorder.record($0) }
        let monitor = StubMonitor(samples: [busy(0.5), .idle])
        let runner = BackgroundDownloadRunner(
            gate: gate,
            monitor: monitor,
            cancellation: BackgroundWorkCancellation(),
            timeout: 30,
            pollInterval: 0.01
        )

        await runner.run()

        XCTAssertEqual(recorder.recorded, [true])
        XCTAssertEqual(monitor.resumeCount, 1)
        XCTAssertEqual(monitor.pauseCount, 0, "a drained task must not pause completed downloads")
    }

    @MainActor
    func testRunnerTimesOutTruthfullyWhenWorkRemains() async {
        let recorder = Recorder()
        let gate = BackgroundTaskCompletionGate { recorder.record($0) }
        let monitor = StubMonitor(samples: [busy(0.1)])
        let runner = BackgroundDownloadRunner(
            gate: gate,
            monitor: monitor,
            cancellation: BackgroundWorkCancellation(),
            timeout: 0,
            pollInterval: 0.01
        )

        await runner.run()

        XCTAssertEqual(recorder.recorded, [false], "leftover work must not be reported as success")
    }

    @MainActor
    func testRunnerExpirationPausesAndReportsFailureOnce() async {
        let recorder = Recorder()
        let gate = BackgroundTaskCompletionGate { recorder.record($0) }
        let monitor = StubMonitor(samples: [busy(0.1)])
        let runner = BackgroundDownloadRunner(
            gate: gate,
            monitor: monitor,
            cancellation: BackgroundWorkCancellation(),
            timeout: 30,
            pollInterval: 5,
            pauseOnCancellation: true
        )

        let run = Task { await runner.run() }
        // Let the loop reach its first sleep, then expire it the way the system would.
        try? await Task.sleep(for: .milliseconds(50))
        runner.cancellation.cancel()
        await run.value

        XCTAssertEqual(recorder.recorded, [false])
        XCTAssertEqual(monitor.pauseCount, 1)
        XCTAssertTrue(gate.currentOutcome.expired)
    }

    /// `start()` twice must produce one monitor and one completion.
    @MainActor
    func testStartingTwiceDoesNotStackMonitors() async {
        let recorder = Recorder()
        let gate = BackgroundTaskCompletionGate { recorder.record($0) }
        let monitor = StubMonitor(samples: [.idle])
        let runner = BackgroundDownloadRunner(
            gate: gate,
            monitor: monitor,
            cancellation: BackgroundWorkCancellation(),
            timeout: 30,
            pollInterval: 0.01
        )

        runner.start()
        runner.start()

        // Let the first monitor settle.
        for _ in 0..<50 where !gate.currentOutcome.isClosed {
            await Task.yield()
        }

        XCTAssertEqual(recorder.recorded.count, 1)
        XCTAssertEqual(monitor.resumeCount, 1, "a second start must not resume downloads again")
    }

    /// An expiration arriving after the worker already finished must not add a second report.
    @MainActor
    func testRunnerLateExpirationAfterSuccessIsIgnored() async {
        let recorder = Recorder()
        let gate = BackgroundTaskCompletionGate { recorder.record($0) }
        let monitor = StubMonitor(samples: [.idle])
        let runner = BackgroundDownloadRunner(
            gate: gate,
            monitor: monitor,
            cancellation: BackgroundWorkCancellation(),
            timeout: 30,
            pollInterval: 0.01
        )

        await runner.run()
        runner.cancellation.cancel()
        gate.expire()

        XCTAssertEqual(recorder.recorded, [true])
    }
}
