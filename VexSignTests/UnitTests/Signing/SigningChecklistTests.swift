//
//  SigningChecklistTests.swift
//  VexSignTests
//
//  The ten signing steps: each one is marked only from evidence.
//

import XCTest
@testable import VexSign

final class SigningChecklistTests: XCTestCase {
	private typealias Step = SigningChecklistStep

	private func statuses(_ evidence: SigningChecklistEvidence) -> [Step.Status] {
		evidence.rows.map(\.status)
	}

	func testThereAreTenStepsInRunOrder() {
		XCTAssertEqual(
			Step.allCases,
			[.identity, .preflight, .copy, .modify, .thin, .inject, .sign, .verify, .register, .install]
		)
		XCTAssertEqual(Step.allCases.compactMap(\.stage), SigningStage.allCases, "Every engine stage has exactly one step")
		XCTAssertEqual(SigningChecklistEvidence().rows.count, 10)
	}

	func testNothingIsMarkedBeforeAnythingIsKnown() {
		XCTAssertEqual(
			statuses(SigningChecklistEvidence()),
			Array(repeating: .pending, count: 9) + [.separate]
		)
	}

	func testChecksBeforeTheRunShowTheirOwnOutcome() {
		var evidence = SigningChecklistEvidence(identity: .passed, preflight: .passedWithWarnings(2))
		XCTAssertEqual(evidence.status(of: .identity), .completed)
		XCTAssertEqual(evidence.status(of: .preflight), .completed)
		XCTAssertNotNil(evidence.rows[1].detail, "Warnings are counted, not hidden")

		evidence = SigningChecklistEvidence(identity: .failed("expired"), preflight: .failed("profile"))
		XCTAssertEqual(evidence.status(of: .identity), .failed)
		XCTAssertEqual(evidence.rows[0].detail, "expired")
		XCTAssertEqual(evidence.rows[1].detail, "profile")

		evidence = SigningChecklistEvidence(identity: .notNeeded)
		XCTAssertEqual(evidence.status(of: .identity), .notNeeded)
		XCTAssertEqual(evidence.status(of: .preflight), .pending, "A preflight that never ran is not a pass")
	}

	func testARunningStageIsActiveAndEarlierOnesAreCompleteOrSkipped() {
		let run = SigningWorkflowSnapshot(reached: [.copying, .modifying, .signing], current: .signing, running: true)
		let evidence = SigningChecklistEvidence(identity: .passed, preflight: .passed, run: run)

		XCTAssertEqual(evidence.status(of: .copy), .completed)
		XCTAssertEqual(evidence.status(of: .modify), .completed)
		XCTAssertEqual(evidence.status(of: .thin), .skipped, "The run moved past thinning without reporting it")
		XCTAssertEqual(evidence.status(of: .inject), .skipped)
		XCTAssertEqual(evidence.status(of: .sign), .active)
		XCTAssertEqual(evidence.status(of: .verify), .pending)
		XCTAssertEqual(evidence.status(of: .register), .pending)
	}

	func testAStageThatCouldStillHappenIsNotCalledSkipped() {
		let run = SigningWorkflowSnapshot(reached: [.copying], current: .copying, running: true)
		for step in [Step.modify, .thin, .inject, .sign, .verify, .register] {
			XCTAssertEqual(SigningChecklistEvidence(run: run).status(of: step), .pending, "\(step)")
		}
	}

	func testFailureAndCancellationSitOnTheStageWhereTheRunStopped() {
		let failed = SigningWorkflowSnapshot(reached: [.copying, .injecting], current: .injecting, failed: true)
		XCTAssertEqual(SigningChecklistEvidence(run: failed).status(of: .inject), .failed)
		XCTAssertEqual(SigningChecklistEvidence(run: failed).status(of: .copy), .completed)
		XCTAssertEqual(SigningChecklistEvidence(run: failed).status(of: .sign), .pending)

		let cancelled = SigningWorkflowSnapshot(reached: [.copying, .signing], current: .signing, cancelled: true)
		XCTAssertEqual(SigningChecklistEvidence(run: cancelled).status(of: .sign), .cancelled)
	}

	func testVerifyNeedsTheEnginesOwnVerdict() {
		let unverified = SigningWorkflowSnapshot(
			reached: [.copying, .signing, .verifying, .registering], current: .registering, running: true
		)
		XCTAssertEqual(SigningChecklistEvidence(run: unverified).status(of: .verify), .pending)

		var verified = unverified
		verified.verified = true
		XCTAssertEqual(SigningChecklistEvidence(run: verified).status(of: .verify), .completed)

		// A run that never reported verification did not verify, even if it "succeeded".
		let noVerify = SigningWorkflowSnapshot(reached: [.copying, .signing, .registering], succeeded: true)
		XCTAssertEqual(SigningChecklistEvidence(run: noVerify).status(of: .verify), .pending)
	}

	func testAFinishedRunCompletesWhatItReportedAndNeverInstall() {
		let run = SigningWorkflowSnapshot(
			reached: [.copying, .modifying, .signing, .verifying, .registering],
			current: .registering, succeeded: true, verified: true
		)
		XCTAssertEqual(
			statuses(SigningChecklistEvidence(identity: .passed, preflight: .passed, run: run)),
			[.completed, .completed, .completed, .completed, .skipped, .skipped, .completed, .completed, .completed, .separate]
		)
	}

	func testEveryStepAndStatusHasATitle() {
		for step in Step.allCases { XCTAssertFalse(step.title.isEmpty, "\(step)") }
		let all: [Step.Status] = [.pending, .active, .completed, .failed, .cancelled, .skipped, .notNeeded, .separate]
		for status in all {
			XCTAssertFalse(status.title.isEmpty)
			XCTAssertFalse(status.icon.isEmpty)
		}
	}
}
