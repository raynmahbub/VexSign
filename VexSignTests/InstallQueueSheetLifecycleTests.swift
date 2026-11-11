//
//  InstallQueueSheetLifecycleTests.swift
//  VexSignTests
//
//  Regression tests for the installation sheet: it stayed visible showing "Installing" while iOS
//  worked, and the races around leaving it — Skip, Retry, a queue reset, a completion from an
//  abandoned run — were decided by an `if` chain inside the view where nothing could assert them.
//
//  The presentation rules now live in `InstallQueueSurface` and the race rules in `InstallQueue`'s
//  static guards, so both are testable without a window, an installer or a device.
//

import Foundation
import IDeviceSwift
import XCTest
@testable import VexSign

final class InstallQueueSheetLifecycleTests: XCTestCase {
	private let entry = "entry-1"

	// MARK: - What the sheet shows

	func testAnIdleQueuePresentsNothing() {
		let surface = InstallQueueSurface.resolve(isPresented: false, isFinished: false,
			failureTitle: nil, hasInstaller: false, isPaused: false, currentEntryID: nil)
		XCTAssertEqual(surface, .hidden)
		XCTAssertFalse(surface.isMonitoring)
	}

	func testAnInstallationInFlightStaysVisible() {
		// The reported bug in one direction: the sheet must not vanish while iOS is genuinely
		// installing, and must keep saying which app it is installing.
		let surface = InstallQueueSurface.resolve(isPresented: true, isFinished: false,
			failureTitle: nil, hasInstaller: true, isPaused: false, currentEntryID: entry)
		XCTAssertEqual(surface, .installing(entryID: entry))
		XCTAssertTrue(surface.isMonitoring)
		XCTAssertTrue(surface.isActionable, "Stop Monitoring has to stay reachable during an install")
	}

	func testPackagingBeforeAnInstallerExistsIsNotAnEmptySheet() {
		let surface = InstallQueueSurface.resolve(isPresented: true, isFinished: false,
			failureTitle: nil, hasInstaller: false, isPaused: false, currentEntryID: entry)
		XCTAssertEqual(surface, .preparing)
		XCTAssertTrue(surface.isMonitoring)
		XCTAssertFalse(surface.isActionable, "Packaging is transient; it ends in a card or a report")
	}

	func testAFinishedRunTransitionsToTheSummary() {
		let surface = InstallQueueSurface.resolve(isPresented: true, isFinished: true,
			failureTitle: nil, hasInstaller: false, isPaused: false, currentEntryID: entry,
			succeeded: 2, failed: 1)
		XCTAssertEqual(surface, .finished(succeeded: 2, failed: 1))
		XCTAssertFalse(surface.isMonitoring, "A terminal outcome stops monitoring")
	}

	func testAFinishedRunOutranksALeftoverInstaller() {
		// The success animation window: the installer may still be referenced while the run has
		// already reached its end. The summary is what the user is owed.
		let surface = InstallQueueSurface.resolve(isPresented: true, isFinished: true,
			failureTitle: nil, hasInstaller: true, isPaused: false, currentEntryID: entry)
		XCTAssertEqual(surface, .finished(succeeded: 0, failed: 0))
	}

	func testAFailurePresentsRecoveryInsteadOfASpinner() {
		let surface = InstallQueueSurface.resolve(isPresented: true, isFinished: false,
			failureTitle: "Install Failed", hasInstaller: true, isPaused: false, currentEntryID: entry)
		XCTAssertEqual(surface, .report(title: "Install Failed", entryID: entry))
		XCTAssertFalse(surface.isMonitoring, "Nothing is being watched any more; the report is")
		XCTAssertTrue(surface.isActionable)
	}

	func testAFailureOutranksTheInstallerCard() {
		let reporting = InstallQueueSurface.resolve(isPresented: true, isFinished: false,
			failureTitle: "Installation Not Confirmed", hasInstaller: true, isPaused: false, currentEntryID: entry)
		let installing = InstallQueueSurface.resolve(isPresented: true, isFinished: false,
			failureTitle: nil, hasInstaller: true, isPaused: false, currentEntryID: entry)
		XCTAssertEqual(reporting, .report(title: "Installation Not Confirmed", entryID: entry))
		XCTAssertNotEqual(reporting, installing)
	}

	func testAPausedQueueStaysActionable() {
		let surface = InstallQueueSurface.resolve(isPresented: true, isFinished: false,
			failureTitle: nil, hasInstaller: false, isPaused: true, currentEntryID: entry)
		XCTAssertEqual(surface, .paused(entryID: entry))
		XCTAssertTrue(surface.isMonitoring)
		XCTAssertTrue(surface.isActionable)
	}

	func testAnUnconfirmedOutcomeReleasesTheSheetButKeepsTheReport() {
		// The reported bug in the other direction: an install iOS never confirmed must not hold the
		// whole app behind an unobservable spinner. The sheet goes; the report stays reachable.
		let presented = InstallQueueSurface.resolve(isPresented: true, isFinished: false,
			failureTitle: "Installation Not Confirmed", hasInstaller: false, isPaused: false, currentEntryID: entry)
		let released = InstallQueueSurface.resolve(isPresented: false, isFinished: false,
			failureTitle: "Installation Not Confirmed", hasInstaller: false, isPaused: false, currentEntryID: entry)
		XCTAssertEqual(presented, .report(title: "Installation Not Confirmed", entryID: entry))
		XCTAssertEqual(released, .hidden)
		XCTAssertFalse(released.isMonitoring)
	}

	func testNoSurfaceMonitorsForeverWithoutEitherAnInstallerOrAReport() {
		// Every presented surface is either monitoring something real or offering a way out.
		let surfaces: [InstallQueueSurface] = [
			.hidden,
			.finished(succeeded: 1, failed: 0),
			.report(title: "Install Failed", entryID: entry),
			.installing(entryID: entry),
			.paused(entryID: entry),
			.preparing
		]
		for surface in surfaces {
			XCTAssertTrue(surface.isMonitoring || surface.isActionable || surface == .hidden,
				"\(surface) would leave the user watching nothing with no way out")
		}
	}

	// MARK: - Failure kinds

	@MainActor
	func testFailureKindsKeepFourSituationsApart() {
		let unconfirmed = InstallQueue.FailureKind.resolve(
			error: InstallConfirmation.Failure(verdict: .timedOutVerifying), needsTrust: false)
		let neverStarted = InstallQueue.FailureKind.resolve(
			error: InstallConfirmation.Failure(verdict: .timedOutWaiting), needsTrust: false)
		let notInstalled = InstallQueue.FailureKind.resolve(
			error: InstallConfirmation.Failure(verdict: .notInstalled), needsTrust: false)
		let plain = InstallQueue.FailureKind.resolve(
			error: NSError(domain: "Install", code: -1), needsTrust: false)
		let trust = InstallQueue.FailureKind.resolve(
			error: InstallConfirmation.Failure(verdict: .timedOutVerifying), needsTrust: true)

		XCTAssertEqual(unconfirmed, .unconfirmed)
		XCTAssertEqual(neverStarted, .unconfirmed)
		XCTAssertEqual(notInstalled, .unconfirmed)
		XCTAssertEqual(plain, .failed)
		XCTAssertEqual(trust, .needsTrust, "A trust problem outranks the verdict: retrying cannot fix it")
	}

	@MainActor
	func testAnUnconfirmedInstallIsNotRecordedAsAFailure() {
		XCTAssertFalse(InstallQueue.FailureKind.unconfirmed.recordsFailure)
		XCTAssertEqual(InstallQueue.FailureKind.unconfirmed.taskPhase, .unconfirmed)
		XCTAssertTrue(InstallQueue.FailureKind.unconfirmed.releasesSheet)
		// It must not read as a failure to the user either.
		XCTAssertNotEqual(InstallQueue.FailureKind.unconfirmed.title, InstallQueue.FailureKind.failed.title)
	}

	@MainActor
	func testAnInstallThatNeverStartedDoesNotImplyItMightHaveWorked() {
		XCTAssertTrue(InstallQueue.FailureKind.neverStarted.recordsFailure)
		XCTAssertEqual(InstallQueue.FailureKind.neverStarted.taskPhase, .failed)
		XCTAssertFalse(InstallQueue.FailureKind.neverStarted.releasesSheet, "Retry has to stay on screen")
		XCTAssertNotEqual(InstallQueue.FailureKind.neverStarted.summary, InstallQueue.FailureKind.unconfirmed.summary,
			"Nothing was sent, so the 'it may already be installed' wording would be a lie")
	}

	@MainActor
	func testAGenuineFailureKeepsItsRecoveryActionsOnScreen() {
		let kinds: [InstallQueue.FailureKind] = [.failed, .needsTrust, .neverStarted]
		for kind in kinds {
			XCTAssertTrue(kind.recordsFailure)
			XCTAssertEqual(kind.taskPhase, .failed)
			XCTAssertFalse(kind.releasesSheet)
			XCTAssertFalse(kind.title.isEmpty)
			XCTAssertFalse(kind.summary.isEmpty)
		}
		XCTAssertNotEqual(InstallQueue.FailureKind.needsTrust.title, InstallQueue.FailureKind.failed.title)
	}

	@MainActor
	func testEveryFailureKindIsDistinct() {
		let kinds = [InstallQueue.FailureKind.needsTrust, .neverStarted, .unconfirmed, .failed]
		XCTAssertEqual(Set(kinds.map(\.title)).count, kinds.count)
		XCTAssertEqual(Set(kinds.map(\.summary)).count, kinds.count)
	}

	@MainActor
	func testAFailurePresentationCarriesTheRecoveryContext() {
		let presentation = InstallQueue.FailurePresentation(
			title: InstallQueue.FailureKind.needsTrust.title,
			message: InstallQueue.FailureKind.needsTrust.summary,
			details: "certificate verify failed",
			needsTrust: true,
			canRetryLocally: true,
			waitingCount: 2
		)
		XCTAssertTrue(presentation.needsTrust)
		XCTAssertTrue(presentation.canRetryLocally)
		XCTAssertEqual(presentation.waitingCount, 2)
		XCTAssertFalse(presentation.id.uuidString.isEmpty)
	}

	// MARK: - Progress is never manufactured

	func testAPercentageIsOnlyShownWhenACounterProducedIt() {
		XCTAssertNil(InstallerStatusViewModel.displayedPercentage(phase: .waitingForStart, overall: 0, isCompleted: false))
		XCTAssertNil(InstallerStatusViewModel.displayedPercentage(phase: .waitingForStart, overall: 0.4, isCompleted: false))
		XCTAssertNil(InstallerStatusViewModel.displayedPercentage(phase: .verifying, overall: 0.99, isCompleted: false),
			"Verification deliberately holds below 1.0; printing 99% would claim progress the device did not report")
		XCTAssertNil(InstallerStatusViewModel.displayedPercentage(phase: .finished(.installed), overall: 0.99, isCompleted: false))
		XCTAssertEqual(InstallerStatusViewModel.displayedPercentage(phase: .downloading, overall: 0.42, isCompleted: false), 42)
		XCTAssertEqual(InstallerStatusViewModel.displayedPercentage(phase: .downloading, overall: 1, isCompleted: true), 100)
	}

	func testDegenerateProgressValuesNeverBecomeAPercentage() {
		for value in [Double.nan, .infinity, -.infinity, -1, 0] {
			XCTAssertNil(InstallerStatusViewModel.displayedPercentage(phase: .downloading, overall: value, isCompleted: false),
				"\(value) is not a counter reading")
		}
		// A counter already at full while still downloading is a stale read, not progress.
		XCTAssertNil(InstallerStatusViewModel.displayedPercentage(phase: .downloading, overall: 1, isCompleted: false))
	}

	// MARK: - Attempt fencing

	@MainActor
	func testAttemptIdentifiersAreUniquePerRunAndEntry() {
		let first = InstallQueue.attemptID(runGeneration: 0, taskID: "task-1", entryID: "entry-1")
		let sameRunOtherEntry = InstallQueue.attemptID(runGeneration: 0, taskID: "task-1", entryID: "entry-2")
		let laterRun = InstallQueue.attemptID(runGeneration: 1, taskID: "task-1", entryID: "entry-1")
		let untracked = InstallQueue.attemptID(runGeneration: 0, taskID: nil, entryID: "entry-1")

		XCTAssertNotEqual(first, sameRunOtherEntry)
		XCTAssertNotEqual(first, laterRun, "A reset run must not reuse the attempt it abandoned")
		XCTAssertNotEqual(first, untracked)
		XCTAssertFalse(untracked.isEmpty)
		XCTAssertEqual(Set([first, sameRunOtherEntry, laterRun, untracked]).count, 4)
	}

	@MainActor
	func testAStaleCompletionCannotEndTheAttemptInFlight() {
		XCTAssertTrue(InstallQueue.mayEndAttempt(registered: "attempt-2", reportedByCompletion: "attempt-2"))
		XCTAssertFalse(InstallQueue.mayEndAttempt(registered: "attempt-2", reportedByCompletion: "attempt-1"))
		// The queue retiring its own installer has no completion to compare against.
		XCTAssertTrue(InstallQueue.mayEndAttempt(registered: "attempt-2", reportedByCompletion: nil))
		XCTAssertFalse(InstallQueue.mayEndAttempt(registered: nil, reportedByCompletion: "attempt-1"))
		XCTAssertFalse(InstallQueue.mayEndAttempt(registered: nil, reportedByCompletion: nil))
		XCTAssertFalse(InstallQueue.mayEndAttempt(registered: "", reportedByCompletion: nil))
	}

	// MARK: - Scheduled-work races

	@MainActor
	func testScheduledWorkFromAnAbandonedRunCannotAdvanceANewerOne() {
		XCTAssertTrue(InstallQueue.mayRunScheduledWork(scheduledGeneration: 3, currentGeneration: 3,
			scheduledEntryID: entry, currentEntryID: entry))
		XCTAssertFalse(InstallQueue.mayRunScheduledWork(scheduledGeneration: 3, currentGeneration: 4,
			scheduledEntryID: entry, currentEntryID: entry),
			"The queue was reset and restarted underneath this completion")
		XCTAssertFalse(InstallQueue.mayRunScheduledWork(scheduledGeneration: 3, currentGeneration: 3,
			scheduledEntryID: entry, currentEntryID: "entry-2"),
			"The queue moved on to another app")
		XCTAssertFalse(InstallQueue.mayRunScheduledWork(scheduledGeneration: 3, currentGeneration: 3,
			scheduledEntryID: entry, currentEntryID: nil))
	}

	@MainActor
	func testAFinishedRunCannotDismissAQueueStartedAfterIt() {
		XCTAssertTrue(InstallQueue.mayDismissFinishedRun(scheduledGeneration: 1, currentGeneration: 1,
			isFinished: true, isSheetPresented: false))
		XCTAssertFalse(InstallQueue.mayDismissFinishedRun(scheduledGeneration: 1, currentGeneration: 2,
			isFinished: true, isSheetPresented: false),
			"A new installation started inside the dismissal window")
		XCTAssertFalse(InstallQueue.mayDismissFinishedRun(scheduledGeneration: 1, currentGeneration: 1,
			isFinished: false, isSheetPresented: false))
		XCTAssertFalse(InstallQueue.mayDismissFinishedRun(scheduledGeneration: 1, currentGeneration: 1,
			isFinished: true, isSheetPresented: true))
	}

	@MainActor
	func testSkipIgnoresStaleTapsAndFailureActionsStayAvailable() {
		// A completion can land just before SwiftUI removes the Skip control.
		XCTAssertFalse(InstallQueue.canSkip(outcome: .succeeded, hasFailure: false))
		XCTAssertFalse(InstallQueue.canSkip(outcome: .skipped, hasFailure: false))
		XCTAssertTrue(InstallQueue.canSkip(outcome: .pending, hasFailure: false))
		XCTAssertTrue(InstallQueue.canSkip(outcome: .failed("Install failed"), hasFailure: true))
	}

	@MainActor
	func testRetryCannotRaceAnOldCompletionThroughTheScheduler() async {
		let scheduler = InstallQueueAdvanceScheduler()
		var advances: [String] = []

		// What Retry does: cancel the pending success advance before starting over.
		scheduler.schedule(after: 0.03) { advances.append("stale") }
		scheduler.cancel()
		scheduler.schedule(after: 0.02) { advances.append("retry") }

		try? await Task.sleep(nanoseconds: 150_000_000)
		XCTAssertEqual(advances, ["retry"], "An old completion must not advance the queue after a retry")
	}

	@MainActor
	func testAResetCancelsEveryPendingTransition() async {
		let scheduler = InstallQueueAdvanceScheduler()
		var ran = false

		scheduler.schedule(after: 0.02) { ran = true }
		// A reset schedules nothing new and cancels what the abandoned run left behind.
		scheduler.schedule(after: 0.02) { ran = true }
		scheduler.cancel()

		try? await Task.sleep(nanoseconds: 150_000_000)
		XCTAssertFalse(ran, "A queue reset must not be undone by a stale callback")
	}

	// MARK: - The install itself is bounded

	func testThePromptWindowIsBoundedSoTheSheetCannotSpinForever() {
		// `AppInstaller` arms a deadline for the window between opening iOS's prompt and the
		// payload being served, reusing the confirmation engine's own start bound. If either limit
		// went to zero the card would resolve instantly; if it were unbounded the card would never
		// resolve at all.
		let limits = InstallConfirmation.Limits()
		XCTAssertGreaterThan(limits.start, 0)
		XCTAssertGreaterThan(limits.verify, 0)
		XCTAssertGreaterThan(limits.settle, 0)
		XCTAssertGreaterThan(limits.unavailableEvidence, 0)
		XCTAssertLessThanOrEqual(limits.unavailableEvidence, limits.verify)
	}

	func testAnInstallThatNeverStartedIsNotReportedAsInstalled() {
		let unproven: [InstallConfirmation.Verdict] = [.notInstalled, .timedOutWaiting, .timedOutVerifying, .cancelled]
		for verdict in unproven {
			XCTAssertFalse(verdict.provesInstalled, "\(verdict) must never count as an install")
			XCTAssertFalse(verdict.diagnosticCode.isEmpty)
		}
		let proven: [InstallConfirmation.Verdict] = [.installed, .installedOtherVersion("1.0")]
		for verdict in proven {
			XCTAssertTrue(verdict.provesInstalled)
		}
	}

	func testAnUnboundedWaitProducesATerminalVerdictNotASuccess() {
		// The engine's own rule: with no evidence the answer is a timeout, never "installed".
		var confirmation = InstallConfirmation(
			expectation: .init(bundleIdentifier: "com.example.app", version: "1.0"),
			limits: .init(start: 0, verify: 0, settle: 0, unavailableEvidence: 0)
		)
		let phase = confirmation.record(progress: nil, at: Date())
		XCTAssertEqual(phase.verdict, .timedOutWaiting)
		XCTAssertTrue(phase.isFinished)
		XCTAssertFalse((phase.verdict ?? .installed).provesInstalled)
	}
}
