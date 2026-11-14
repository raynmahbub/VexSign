//
//  TaskReceiptOutcomeTests.swift
//  VexSignTests
//
//  What a task receipt says about an attempt that left nothing behind, and about an install
//  that waited on the device.
//
//  Two things a receipt used to leave out:
//
//    * A re-sign that failed ended with the general sentence about task outcomes, under a
//      heading that read "Sign · Failed". Nothing said that a run which fails registers no copy
//      and never touches the copy it was started from, so the receipt read as a verdict on a
//      library copy that was still valid.
//    * An install that waited on verification gave no sign of having been checked at all.
//
//  The sentences are localized, so these tests compare receipts with each other rather than
//  with English text. The lines that are not localized are matched literally.
//

import Foundation
import XCTest
@testable import VexSign

final class TaskReceiptOutcomeTests: XCTestCase {
	private func signTask(endingIn phase: UnifiedTaskPhase) -> UnifiedTask {
		let task = UnifiedTask(kind: .sign, title: "App", phase: .signing)
		task.phase = phase
		return task
	}

	private func installTask(checks: Int?) -> UnifiedTask {
		let task = UnifiedTask(kind: .install, title: "App", phase: .preparingInstallation)
		task.context?.verificationAttempts = checks
		return task
	}

	/// The sentence every task without a more specific one ends with.
	private var generalOutcome: String {
		TaskReceipt.outcome(for: UnifiedTask(kind: .download, title: "App"))
	}

	// MARK: - A signing attempt that produced nothing

	func testAFailedSigningAttemptIsNotReportedWithTheGeneralSentence() {
		let failed = signTask(endingIn: .failed)
		let outcome = TaskReceipt.outcome(for: failed)

		XCTAssertNotEqual(outcome, generalOutcome)
		XCTAssertNotEqual(outcome, TaskReceipt.outcome(for: signTask(endingIn: .completed)), "A failure is not worded as a completed signing")
		XCTAssertTrue(TaskReceipt.report(for: failed).contains(outcome), "The receipt carries the sentence")
	}

	func testACancelledSigningAttemptSaysTheSameAsAFailedOne() {
		// Either way nothing was registered and the copy it started from is as it was.
		XCTAssertEqual(
			TaskReceipt.outcome(for: signTask(endingIn: .cancelled)),
			TaskReceipt.outcome(for: signTask(endingIn: .failed))
		)
	}

	func testAnInterruptedSigningAttemptKeepsTheInterruptionSentence() {
		let interruptedInstall = UnifiedTask(kind: .install, title: "App", phase: .interrupted)

		XCTAssertEqual(TaskReceipt.outcome(for: signTask(endingIn: .interrupted)), TaskReceipt.outcome(for: interruptedInstall))
		XCTAssertNotEqual(TaskReceipt.outcome(for: signTask(endingIn: .interrupted)), TaskReceipt.outcome(for: signTask(endingIn: .failed)))
	}

	func testOnlySigningAttemptsGetTheSentence() {
		let unchanged = TaskReceipt.outcome(for: signTask(endingIn: .failed))

		let failedInstall = UnifiedTask(kind: .install, title: "App", phase: .failed)
		let failedImport = UnifiedTask(kind: .importIPA, title: "App", phase: .failed)
		let stoppedInstall = UnifiedTask(kind: .install, title: "App", phase: .cancelled)

		XCTAssertEqual(TaskReceipt.outcome(for: failedInstall), generalOutcome)
		XCTAssertEqual(TaskReceipt.outcome(for: failedImport), generalOutcome)
		XCTAssertNotEqual(TaskReceipt.outcome(for: stoppedInstall), unchanged, "A stopped install keeps its own wording about iOS")
		XCTAssertNotEqual(TaskReceipt.outcome(for: stoppedInstall), generalOutcome)
	}

	func testASigningAttemptStillRunningIsNotCalledUnchanged() {
		XCTAssertEqual(TaskReceipt.outcome(for: signTask(endingIn: .signing)), generalOutcome)
	}

	// MARK: - How many times the device was asked

	func testAnInstallReceiptCarriesTheNumberOfDeviceChecks() {
		XCTAssertTrue(TaskReceipt.report(for: installTask(checks: 7)).contains("Installation checks: 7"))
		XCTAssertTrue(TaskReceipt.report(for: installTask(checks: 1)).contains("Installation checks: 1"))
	}

	func testAnInstallThatNeverAskedTheDeviceSaysNothingAboutChecks() {
		for checks in [nil, 0, -3] as [Int?] {
			XCTAssertFalse(
				TaskReceipt.report(for: installTask(checks: checks)).contains("Installation checks"),
				"\(String(describing: checks)) is not a number of checks"
			)
		}
	}

	func testACountThatCannotBeRealIsLeftOut() {
		// The record is read back from disk. A receipt exports nothing it cannot vouch for.
		XCTAssertFalse(TaskReceipt.report(for: installTask(checks: 100_001)).contains("Installation checks"))
		XCTAssertFalse(TaskReceipt.report(for: installTask(checks: Int.max)).contains("Installation checks"))
		XCTAssertTrue(TaskReceipt.report(for: installTask(checks: 100_000)).contains("Installation checks: 100000"))
	}

	func testOnlyAnInstallReportsDeviceChecks() {
		let signing = signTask(endingIn: .completed)
		signing.context?.verificationAttempts = 4
		let export = UnifiedTask(kind: .export, title: "App", phase: .extracting)
		export.context?.verificationAttempts = 4

		XCTAssertFalse(TaskReceipt.report(for: signing).contains("Installation checks"))
		XCTAssertFalse(TaskReceipt.report(for: export).contains("Installation checks"))
	}

	func testTheMonitoringDeadlineIsExportedAsItsOwnEvidence() {
		let task = installTask(checks: 12)
		task.context?.confirmationReason = "installation-monitoring-deadline"
		let report = TaskReceipt.report(for: task)

		XCTAssertTrue(report.contains("Result evidence: installation-monitoring-deadline"))
		XCTAssertTrue(report.contains("Installation checks: 12"))
	}

	// MARK: - The count in the history file

	func testTheCheckCountSurvivesTheHistoryFile() throws {
		let task = installTask(checks: 9)
		let data = try JSONEncoder().encode(task.snapshot)
		let restored = UnifiedTask.from(try JSONDecoder().decode(UnifiedTask.Snapshot.self, from: data))

		XCTAssertEqual(restored.context?.verificationAttempts, 9)
		XCTAssertTrue(TaskReceipt.report(for: restored).contains("Installation checks: 9"))
	}

	func testAContextWrittenBeforeTheCountExistedStillDecodes() throws {
		// Task history on disk predates the count. Every stored task has to keep loading.
		let json = #"{"appVersion":"1.0","clientVersion":"1.0 (1)","sourceCommit":"0000000","confirmationReason":"device-confirmed-installed"}"#
		let context = try JSONDecoder().decode(TaskContext.self, from: Data(json.utf8))

		XCTAssertNil(context.verificationAttempts)
		XCTAssertEqual(context.confirmationReason, "device-confirmed-installed")
	}

	func testAContextWithoutACountDoesNotWriteOne() throws {
		let data = try JSONEncoder().encode(TaskContext())
		let text = String(decoding: data, as: UTF8.self)

		XCTAssertFalse(text.contains("verificationAttempts"), "An absent count is absent on disk, not zero")
	}
}
