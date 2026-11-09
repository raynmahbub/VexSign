//
//  InstallEvidenceReportingTests.swift
//  VexSignTests
//
//  Regressions from two field receipts (OTA, 1.2.1):
//
//    Verifying installation +4.9s → Failed +35.0s, evidence installation-evidence-unavailable
//    Verifying installation +4.0s → Failed +34.1s, evidence installation-evidence-unavailable
//
//  Both are the 30s `unavailableEvidence` deadline. On modern iOS the private LaunchServices
//  lookups are filtered, so `InstalledAppProbe` returns nil for an app that installed correctly —
//  and VexSign recorded that as a *failed* install, telling the user to retry an app already on
//  their Home Screen. "No evidence" is now a terminal `unconfirmed` phase, not a failure.
//
//  Also covers the placeholder case: a placeholder is evidence iOS is still installing, so it
//  must not be cut off by the short no-evidence deadline.
//

import Foundation
import XCTest
@testable import VexSign

final class InstallEvidenceReportingTests: XCTestCase {
	private let start = Date(timeIntervalSince1970: 1_800_000_000)

	private func engine() -> InstallConfirmation {
		InstallConfirmation(expectation: .init(bundleIdentifier: "com.example.app", version: "1.0"))
	}

	private func verifying(_ confirmation: inout InstallConfirmation) -> TimeInterval {
		_ = confirmation.beginVerifying(at: start)
		return 0
	}

	// MARK: - No evidence at all

	func testNoEvidenceStillEndsAtTheShortDeadline() {
		var confirmation = engine()
		_ = verifying(&confirmation)
		let phase = confirmation.record(probe: nil, at: start.addingTimeInterval(31))
		XCTAssertEqual(phase.verdict, .timedOutVerifying)
	}

	func testNoEvidenceDoesNotEndEarly() {
		var confirmation = engine()
		_ = verifying(&confirmation)
		XCTAssertEqual(confirmation.record(probe: nil, at: start.addingTimeInterval(10)).verdict, nil)
	}

	func testUnavailableEvidenceIsNotADiagnosisOfRejection() {
		// The distinction the whole fix rests on: this verdict never proved absence.
		XCTAssertFalse(InstallConfirmation.Verdict.timedOutVerifying.provesInstalled)
		XCTAssertNotEqual(InstallConfirmation.Verdict.timedOutVerifying, .notInstalled)
		XCTAssertEqual(InstallConfirmation.Verdict.timedOutVerifying.diagnosticCode,
					   "installation-evidence-unavailable")
	}

	// MARK: - A placeholder is evidence, not silence

	func testPlaceholderKeepsTheFullVerificationWindow() {
		var confirmation = engine()
		_ = verifying(&confirmation)
		let placeholder = InstalledApp(bundleIdentifier: "com.example.app", isInstalled: true, isPlaceholder: true)

		// Past the 30s no-evidence deadline, well inside the 600s verify window.
		XCTAssertEqual(confirmation.record(probe: placeholder, at: start.addingTimeInterval(45)).verdict, nil,
					   "iOS is still writing the app; do not give up on it")
		XCTAssertEqual(confirmation.record(probe: placeholder, at: start.addingTimeInterval(300)).verdict, nil)
	}

	func testPlaceholderThatNeverFinishesStillEnds() {
		var confirmation = engine()
		_ = verifying(&confirmation)
		let placeholder = InstalledApp(bundleIdentifier: "com.example.app", isInstalled: true, isPlaceholder: true)
		XCTAssertEqual(confirmation.record(probe: placeholder, at: start.addingTimeInterval(601)).verdict,
					   .timedOutVerifying)
	}

	func testPlaceholderFollowedByARealReadingIsInstalled() {
		var confirmation = engine()
		_ = verifying(&confirmation)
		let placeholder = InstalledApp(bundleIdentifier: "com.example.app", isInstalled: true, isPlaceholder: true)
		_ = confirmation.record(probe: placeholder, at: start.addingTimeInterval(45))

		let installed = InstalledApp(bundleIdentifier: "com.example.app", isInstalled: true, version: "1.0")
		XCTAssertEqual(confirmation.record(probe: installed, at: start.addingTimeInterval(60)).verdict, .installed)
	}

	func testSilenceAfterAPlaceholderUsesTheShortDeadlineAgain() {
		var confirmation = engine()
		_ = verifying(&confirmation)
		let placeholder = InstalledApp(bundleIdentifier: "com.example.app", isInstalled: true, isPlaceholder: true)
		_ = confirmation.record(probe: placeholder, at: start.addingTimeInterval(10))
		// The probe stopped answering entirely: back to the bounded no-evidence wait.
		XCTAssertEqual(confirmation.record(probe: nil, at: start.addingTimeInterval(31)).verdict,
					   .timedOutVerifying)
	}

	// MARK: - The task phase that reaches the receipt

	func testUnconfirmedIsTerminalAndIsNeitherSuccessNorFailure() {
		XCTAssertTrue(UnifiedTaskPhase.unconfirmed.isTerminal)
		XCTAssertFalse(UnifiedTaskPhase.unconfirmed.isInProgress)
		XCTAssertNotEqual(UnifiedTaskPhase.unconfirmed, .failed)
		XCTAssertNotEqual(UnifiedTaskPhase.unconfirmed, .completed)
	}

	func testAnInstallCanMoveToUnconfirmed() {
		XCTAssertTrue(UnifiedTaskPhase.verifying.canTransition(to: .unconfirmed, kind: .install))
		XCTAssertFalse(UnifiedTaskPhase.unconfirmed.canTransition(to: .installing, kind: .install))
	}

	func testThePhaseSurvivesHistoryRoundTrip() {
		XCTAssertEqual(UnifiedTaskPhase(rawValue: UnifiedTaskPhase.unconfirmed.rawValue), .unconfirmed)
	}

	func testUnconfirmedDoesNotRecordAFailureStage() {
		let task = UnifiedTask(kind: .install, title: "Fixture")
		_ = task.move(to: .verifying, at: start)
		_ = task.move(to: .unconfirmed, at: start.addingTimeInterval(35))
		XCTAssertNil(task.failureStage, "nothing failed; the stage is not a failure stage")
		XCTAssertEqual(task.phase, .unconfirmed)
	}

	func testAFailedInstallStillRecordsItsStage() {
		let task = UnifiedTask(kind: .install, title: "Fixture")
		_ = task.move(to: .verifying, at: start)
		_ = task.move(to: .failed, at: start.addingTimeInterval(35))
		XCTAssertEqual(task.failureStage, .verifying)
	}
}
