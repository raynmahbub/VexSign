//
//  UnifiedTaskPolicyTests.swift
//  VexSignTests
//
//  The center's transition authority was already enforced by `UnifiedTask.move(to:)`. These
//  tests cover the three rules that were implicit before: progress never rewinds inside a stage,
//  a retry is only offered for a stopped task, and one operation does not become two tasks.
//
//  Everything here is a pure function or a value object — no center, no journal, no main actor.
//

import XCTest
@testable import VexSign

final class UnifiedTaskPolicyTests: XCTestCase {
    // MARK: - Progress

    func testProgressIsClampedToOne() {
        XCTAssertEqual(TaskProgressRule.normalized(2.5), 1)
        XCTAssertEqual(TaskProgressRule.normalized(1), 1)
        XCTAssertEqual(TaskProgressRule.normalized(0.25), 0.25)
    }

    func testNegativeProgressIsIndeterminateNotZero() {
        // The documented indeterminate value must survive; clamping it to 0 would turn "we do
        // not know" into "we have not started".
        XCTAssertEqual(TaskProgressRule.normalized(-3), -1)
        XCTAssertEqual(TaskProgressRule.normalized(-0.1), -1)
    }

    func testNonFiniteProgressFallsBackToZero() {
        XCTAssertEqual(TaskProgressRule.normalized(.nan), 0)
        XCTAssertEqual(TaskProgressRule.normalized(.infinity), 1)
    }

    func testProgressDoesNotRewindInsideAStage() {
        XCTAssertEqual(TaskProgressRule.next(previous: 0.6, proposed: 0.4, stageChanged: false), 0.6)
        XCTAssertEqual(TaskProgressRule.next(previous: 0.6, proposed: 0.9, stageChanged: false), 0.9)
        XCTAssertEqual(TaskProgressRule.next(previous: 0.6, proposed: 0.6, stageChanged: false), 0.6)
    }

    func testANewStageMayStartLower() {
        // Extraction after a download legitimately restarts its own zero.
        XCTAssertEqual(TaskProgressRule.next(previous: 0.95, proposed: 0.05, stageChanged: true), 0.05)
    }

    func testIndeterminateReportsDoNotEraseKnownProgress() {
        XCTAssertEqual(TaskProgressRule.next(previous: 0.5, proposed: -1, stageChanged: false), 0.5)
    }

    func testKnownProgressReplacesIndeterminateWithinAStage() {
        XCTAssertEqual(TaskProgressRule.next(previous: -1, proposed: 0.3, stageChanged: false), 0.3)
    }

    func testACompletedTaskReportsFullProgress() {
        XCTAssertEqual(TaskProgressRule.final(phase: .completed, current: 0.42), 1)
        XCTAssertEqual(TaskProgressRule.final(phase: .failed, current: 0.42), 0.42)
        XCTAssertEqual(TaskProgressRule.final(phase: .cancelled, current: 0.9), 0.9)
    }

    // MARK: - Retry

    func testOnlyStoppedTasksCanOfferRetry() {
        for phase in [UnifiedTaskPhase.failed, .cancelled, .unconfirmed] {
            XCTAssertTrue(TaskRetryPolicy.canOffer(phase), "\(phase) should be retryable")
        }
        for phase in [UnifiedTaskPhase.queued, .downloading, .extracting, .signing, .installing,
                      .verifying, .completed, .interrupted, .paused] {
            XCTAssertFalse(TaskRetryPolicy.canOffer(phase), "\(phase) must not offer a retry")
        }
    }

    // MARK: - Submission

    private func task(kind: UnifiedTaskKind, subject: String?, phase: UnifiedTaskPhase) -> UnifiedTask {
        UnifiedTask(kind: kind, title: "t", phase: phase, subjectID: subject)
    }

    func testInFlightMatchesKindAndSubject() {
        let running = task(kind: .sign, subject: "app-uuid", phase: .signing)
        XCTAssertTrue(TaskSubmissionPolicy.inFlight(kind: .sign, subjectID: "app-uuid", in: [running]) === running)
    }

    func testInFlightIgnoresOtherKindsAndSubjects() {
        let running = task(kind: .sign, subject: "app-uuid", phase: .signing)
        XCTAssertNil(TaskSubmissionPolicy.inFlight(kind: .install, subjectID: "app-uuid", in: [running]))
        XCTAssertNil(TaskSubmissionPolicy.inFlight(kind: .sign, subjectID: "other-uuid", in: [running]))
    }

    func testFinishedTasksAreNotDuplicates() {
        let finished = task(kind: .sign, subject: "app-uuid", phase: .completed)
        XCTAssertNil(TaskSubmissionPolicy.inFlight(kind: .sign, subjectID: "app-uuid", in: [finished]))
    }

    func testAnonymousTasksAreNeverDeduplicated() {
        // Two signings with no subject cannot be proven to be the same operation.
        let running = task(kind: .sign, subject: nil, phase: .signing)
        XCTAssertNil(TaskSubmissionPolicy.inFlight(kind: .sign, subjectID: nil, in: [running]))
        XCTAssertNil(TaskSubmissionPolicy.inFlight(kind: .sign, subjectID: "", in: [running]))
    }

    func testOnlyAQueuedDuplicateCanBeAdopted() {
        let queued = task(kind: .install, subject: "app-uuid", phase: .queued)
        XCTAssertTrue(TaskSubmissionPolicy.adoptable(kind: .install, subjectID: "app-uuid", in: [queued]) === queued)

        let running = task(kind: .install, subject: "app-uuid", phase: .installing)
        XCTAssertNil(TaskSubmissionPolicy.adoptable(kind: .install, subjectID: "app-uuid", in: [running]))
    }

    // MARK: - Lifecycle

    func testSignFlowAcceptsItsOwnOrderAndRejectsSkipping() {
        let task = task(kind: .sign, subject: "app", phase: .queued)
        XCTAssertFalse(task.move(to: .installing), "a sign task cannot jump to installation")
        XCTAssertTrue(task.move(to: .signing))
        XCTAssertTrue(task.move(to: .signed))
        XCTAssertTrue(task.move(to: .completed))
        XCTAssertEqual(task.phase, .completed)
    }

    func testCompletedTaskCannotBecomeRunningAgain() {
        let task = task(kind: .sign, subject: "app", phase: .signing)
        XCTAssertTrue(task.move(to: .signed))
        XCTAssertTrue(task.move(to: .completed))
        XCTAssertFalse(task.move(to: .signing), "a finished task must stay finished")
        XCTAssertEqual(task.phase, .completed)
    }

    func testCancelledTaskIsNeverReportedAsCompleted() {
        let task = task(kind: .sign, subject: "app", phase: .signing)
        XCTAssertTrue(task.move(to: .cancelled))
        XCTAssertFalse(task.move(to: .completed))
        XCTAssertFalse(task.move(to: .signed))
        XCTAssertEqual(task.phase, .cancelled)
    }

    func testFailureRemembersTheStageItCameFrom() {
        let task = task(kind: .install, subject: "app", phase: .preparingInstallation)
        XCTAssertTrue(task.move(to: .installing))
        XCTAssertTrue(task.move(to: .failed))
        XCTAssertEqual(task.failureStage, .installing)
        XCTAssertEqual(task.phase, .failed)
    }

    func testInstallFlowCannotSkipStraightToCompleted() {
        let task = task(kind: .install, subject: "app", phase: .queued)
        XCTAssertFalse(task.move(to: .completed))
        XCTAssertTrue(task.move(to: .preparingInstallation))
        XCTAssertTrue(task.move(to: .waitingForIOS))
        XCTAssertTrue(task.move(to: .installing))
        XCTAssertTrue(task.move(to: .verifying))
        XCTAssertTrue(task.move(to: .completed))
    }

    func testInvalidTransitionDoesNotTouchTheRecord() {
        let task = task(kind: .sign, subject: "app", phase: .queued)
        let before = task.stageHistory.count
        XCTAssertFalse(task.move(to: .installing))
        XCTAssertEqual(task.stageHistory.count, before)
        XCTAssertEqual(task.phase, .queued)
    }

    func testRecoverAfterRestartMarksWorkInterruptedWithItsStage() {
        let task = task(kind: .sign, subject: "app", phase: .signing)
        task.recoverAfterRestart()
        XCTAssertEqual(task.phase, .interrupted)
        XCTAssertEqual(task.failureStage, .signing)
        XCTAssertEqual(task.context?.confirmationReason, "interrupted-process-exit")
    }

    func testRecoverAfterRestartLeavesAFinishedTaskAlone() {
        let task = task(kind: .sign, subject: "app", phase: .signing)
        XCTAssertTrue(task.move(to: .completed))
        task.recoverAfterRestart()
        XCTAssertEqual(task.phase, .completed)
    }

    func testHandedOffInstallBecomesUnconfirmedRatherThanInterrupted() {
        // iOS may have finished an install while the process was gone; neither outcome can be
        // inferred, so the record must not claim either.
        let task = task(kind: .install, subject: "app", phase: .installing)
        task.context?.handoffAt = Date()
        task.recoverAfterRestart()
        XCTAssertEqual(task.phase, .unconfirmed)
        XCTAssertNil(task.failureStage)
        XCTAssertEqual(task.context?.confirmationReason, "process-exit-installation-unconfirmed")
    }

    func testStageHistoryKeepsTheOrderItHappenedIn() {
        let task = task(kind: .sign, subject: "app", phase: .queued)
        XCTAssertTrue(task.move(to: .signing))
        XCTAssertTrue(task.move(to: .signed))
        XCTAssertEqual(task.stageHistory.map(\.phase), [.queued, .signing, .signed])
    }

    // MARK: - Mirroring a download that disappeared

    func testAVanishedDownloadIsNeverReportedAsCompleted() {
        // DownloadManager removes the row on a transfer error, on the 8 GiB size limit and when
        // the user stops the transfer. None of those is a finished download, so none of them may
        // become `.completed` just because the row is gone.
        for phase: UnifiedTaskPhase in [.queued, .downloading, .paused, .verifying, .importing, .extracting] {
            XCTAssertEqual(TaskMirrorPolicy.vanished(phase), .interrupted, "\(phase) must not read as success")
            XCTAssertNotEqual(TaskMirrorPolicy.vanished(phase), .completed)
        }
    }

    func testAFinishedDownloadKeepsItsOwnVerdict() {
        // A completed download is removed from the manager only after the mirror already
        // finalized it; re-labelling that would rewrite history from an absence.
        for phase: UnifiedTaskPhase in [.completed, .failed, .cancelled, .interrupted, .unconfirmed] {
            XCTAssertNil(TaskMirrorPolicy.vanished(phase), "\(phase) is already decided")
        }
    }

    func testTheMirrorVerdictIsAlwaysTerminal() {
        // Whatever the policy returns must be a phase the transition authority will accept and
        // the journal will stop tracking, otherwise the record lingers in the live list forever.
        for phase in UnifiedTaskPhase.allCases {
            guard let verdict = TaskMirrorPolicy.vanished(phase) else { continue }
            XCTAssertTrue(verdict.isTerminal, "\(verdict) would stay in flight")
        }
    }

    func testAnInterruptedVerdictCanBeAppliedToALiveMirror() throws {
        for kind: UnifiedTaskKind in [.download, .importIPA] {
            let running = task(kind: kind, subject: "dl", phase: .downloading)
            let verdict = try XCTUnwrap(TaskMirrorPolicy.vanished(running.phase))
            XCTAssertTrue(running.move(to: verdict), "\(kind) must accept the mirroring verdict")
            XCTAssertEqual(running.phase, .interrupted)
            XCTAssertTrue(running.phase.isTerminal)
            XCTAssertFalse(TaskRetryPolicy.canOffer(running.phase), "a lost transfer is not a retryable failure record")
        }
    }

    func testAnInterruptedMirrorDoesNotClaimTheDownloadFailed() {
        // We know the transfer did not finish; we do not know why. Marking it failed would put an
        // invented error in front of the user for a download they stopped themselves.
        let running = task(kind: .download, subject: "dl", phase: .downloading)
        _ = running.move(to: .interrupted)
        XCTAssertNil(running.failureStage)
        XCTAssertNil(running.errorText)
        XCTAssertEqual(running.displayPhaseTitle, UnifiedTaskPhase.interrupted.title)
    }
}
