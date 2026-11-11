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
//  lookups are filtered, so `InstalledAppProbe` can return nil even when an app installed
//  correctly. The timeout is deliberately unconfirmed, not proof of rejection; the UI still
//  reports that it could not verify and tells the user to check before retrying.
//
//  Also covers the placeholder case: a placeholder is evidence iOS is still installing, so it
//  must not be cut off by the short no-evidence deadline.
//

import Foundation
import IDeviceSwift
import NimbleExtensions
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

	func testPlaceholderKeepsVerifyingButOnlyForTheBoundedWindow() {
		var confirmation = engine()
		_ = verifying(&confirmation)
		let placeholder = InstalledApp(bundleIdentifier: "com.example.app", isInstalled: true, isPlaceholder: true)

		// A placeholder is positive installation activity, so it gets the full
		// two-minute window rather than the short no-evidence deadline.
		XCTAssertEqual(confirmation.record(probe: placeholder, at: start.addingTimeInterval(45)).verdict, nil,
					   "iOS is still writing the app; do not give up on it")
		XCTAssertEqual(confirmation.record(probe: placeholder, at: start.addingTimeInterval(119)).verdict, nil)
		XCTAssertEqual(confirmation.record(probe: placeholder, at: start.addingTimeInterval(120)).verdict,
					   .timedOutVerifying)
	}

	func testPlaceholderThatNeverFinishesEndsAtTheBoundedDeadline() {
		var confirmation = engine()
		_ = verifying(&confirmation)
		let placeholder = InstalledApp(bundleIdentifier: "com.example.app", isInstalled: true, isPlaceholder: true)
		XCTAssertEqual(confirmation.record(probe: placeholder, at: start.addingTimeInterval(121)).verdict,
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
		let task = UnifiedTask(kind: .install, title: "Fixture", phase: .installing)
		_ = task.move(to: .verifying, at: start)
		_ = task.move(to: .unconfirmed, at: start.addingTimeInterval(35))
		XCTAssertNil(task.failureStage, "nothing failed; the stage is not a failure stage")
		XCTAssertEqual(task.phase, .unconfirmed)
	}

	func testAFailedInstallStillRecordsItsStage() {
		let task = UnifiedTask(kind: .install, title: "Fixture", phase: .installing)
		_ = task.move(to: .verifying, at: start)
		_ = task.move(to: .failed, at: start.addingTimeInterval(35))
		XCTAssertEqual(task.failureStage, .verifying)
	}
}

extension InstallEvidenceReportingTests {
    func testSupportedInventoryUnavailableNeverClaimsPresence() {
        XCTAssertNil(UnavailableInstallationProbe().installedApp(for: "com.example.app"))
    }

    func testPersistedHandoffRecoversAsUnconfirmed() throws {
        let task = UnifiedTask(kind: .install, title: "Example", phase: .waitingForIOS)
        task.context?.expectedBundleIdentifier = "com.example.app"
        task.context?.artifactID = "signed-artifact"
        task.context?.handoffAt = Date(timeIntervalSince1970: 100)
        task.context?.monitoringActive = true
        let data = try JSONEncoder().encode(task.snapshot)
        let snapshot = try JSONDecoder().decode(UnifiedTask.Snapshot.self, from: data)
        let recovered = UnifiedTask.from(snapshot)
        recovered.recoverAfterRestart(at: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(recovered.phase, .unconfirmed)
        XCTAssertEqual(recovered.context?.expectedBundleIdentifier, "com.example.app")
        XCTAssertEqual(recovered.context?.artifactID, "signed-artifact")
        XCTAssertEqual(recovered.context?.monitoringActive, false)
        XCTAssertEqual(recovered.context?.confirmationReason, "process-exit-installation-unconfirmed")
    }

    func testInstallationTransitionsDoNotMoveBackwards() {
        XCTAssertTrue(UnifiedTaskPhase.queued.canTransition(to: .preparingInstallation, kind: .install))
        XCTAssertTrue(UnifiedTaskPhase.preparingInstallation.canTransition(to: .waitingForIOS, kind: .install))
        XCTAssertTrue(UnifiedTaskPhase.waitingForIOS.canTransition(to: .installing, kind: .install))
        XCTAssertFalse(UnifiedTaskPhase.installing.canTransition(to: .waitingForIOS, kind: .install))
        XCTAssertFalse(UnifiedTaskPhase.queued.canTransition(to: .completed, kind: .install))
        XCTAssertFalse(UnifiedTaskPhase.verifying.canTransition(to: .installing, kind: .install))
    }

    func testUnconfirmedCannotBecomeSuccessFromLateCallback() {
        let task = UnifiedTask(kind: .install, title: "Example", phase: .waitingForIOS)
        XCTAssertTrue(task.move(to: .unconfirmed))
        XCTAssertFalse(task.move(to: .completed))
        XCTAssertEqual(task.phase, .unconfirmed)
    }

    @MainActor
    func testHandoffTimeoutIsNeitherCancellationNorFailure() {
        XCTAssertEqual(InstallQueue.FailureKind.resolve(
            error: InstallConfirmation.Failure(verdict: .timedOutWaiting), needsTrust: false), .unconfirmed)
        XCTAssertFalse(InstallConfirmation.Verdict.timedOutWaiting.provesInstalled)
    }
}


extension InstallEvidenceReportingTests {
    private func presentation(
        _ status: InstallerStatusViewModel.InstallerStatus,
        _ phase: InstallConfirmation.Phase = .waitingForStart,
        taskPhase: UnifiedTaskPhase? = nil,
        isExport: Bool = false
    ) -> InstallPresentation {
        InstallPresentation.resolve(status: status, phase: phase, taskPhase: taskPhase, isExport: isExport)
    }

    func testReadyAndWaitingShowConfirmationWithoutSuccessIcon() {
        let state = presentation(.ready)
        XCTAssertEqual(state, .awaitingConfirmation)
        XCTAssertEqual(state.label(), String.localized("Waiting for iOS confirmation"))
        XCTAssertEqual(state.accessibilityLabel, String.localized("Waiting for iOS confirmation"))
        XCTAssertNotEqual(state.symbol, InstallPresentation.installed.symbol)
        XCTAssertFalse(state.isTerminal)
    }

    func testManifestAndWaitingTaskShowActualHandoff() {
        XCTAssertEqual(presentation(.none), .preparing)
        XCTAssertEqual(presentation(.sendingManifest), .sendingManifest)
        XCTAssertEqual(presentation(.sendingManifest, taskPhase: .waitingForIOS), .awaitingConfirmation)
        XCTAssertEqual(presentation(.sendingPayload, taskPhase: .waitingForIOS), .installing)
        XCTAssertEqual(presentation(.sendingPayload, .downloading), .installing)
    }

    func testVerificationHasSeparateTextIconAndAccessibility() {
        let state = presentation(.installing, .verifying)
        XCTAssertEqual(state, .verifying)
        XCTAssertEqual(state.label(), String.localized("Verifying installation"))
        XCTAssertEqual(state.accessibilityLabel, String.localized("Verifying installation"))
        XCTAssertNotEqual(state.symbol, InstallPresentation.installed.symbol)
        XCTAssertEqual(state.label(verificationAttempt: 2), InstallVerificationPolicy.statusLabel(attempt: 2))
    }

    func testTransportSuccessAloneNeverMeansInstalled() {
        XCTAssertEqual(presentation(.completed(.success(()))), .verifying)
        XCTAssertEqual(presentation(.completed(.success(())), .verifying), .verifying)
        let verified = presentation(.completed(.success(())), .finished(.installed))
        XCTAssertEqual(verified, .installed)
        XCTAssertEqual(verified.label(), String.localized("Installed"))
        XCTAssertEqual(verified.accessibilityLabel, String.localized("Installation completed"))
        XCTAssertEqual(presentation(.completed(.success(())), isExport: true), .operationCompleted)
    }

    func testTaskTitleOnlyClaimsInstalledWithConfirmationEvidence() {
        let task = UnifiedTask(kind: .install, title: "App", phase: .completed)
        XCTAssertEqual(task.displayPhaseTitle, UnifiedTaskPhase.completed.title)
        task.context?.confirmationReason = "native-installation-completed"
        XCTAssertEqual(task.displayPhaseTitle, String.localized("Installed"))
    }

    func testTimeoutFailureAndAccessibilityNeverInventSuccess() {
        let notConfirmed = presentation(.ready, .finished(.timedOutWaiting))
        XCTAssertEqual(notConfirmed, .unconfirmed)
        XCTAssertEqual(notConfirmed.accessibilityLabel, String.localized("Installation not confirmed"))
        XCTAssertFalse(InstallConfirmation.Verdict.timedOutWaiting.provesInstalled)
        let failure = presentation(.broken(NSError(domain: "test", code: 1)), .verifying)
        XCTAssertEqual(failure, .failed)
        XCTAssertEqual(failure.accessibilityLabel, String.localized("Installation failed"))
        XCTAssertEqual(presentation(.installing, taskPhase: .unconfirmed), .unconfirmed)
        XCTAssertEqual(presentation(.completed(.success(())), .finished(.installed), taskPhase: .unconfirmed), .unconfirmed)
    }

    @MainActor
    func testLateTransportCannotReplaceConfirmedCompletionPresentation() {
        let model = InstallerStatusViewModel(status: .installing)
        AppInstaller.Outcome.installed.publishConfirmedCompletion(to: model)
        model.updateTransportStatus(.sendingPayload)
        XCTAssertEqual(presentation(model.status, .finished(.installed)), .installed)
        XCTAssertTrue(model.isCompleted)
    }

    @MainActor
    func testStoppingMonitoringAfterHandoffDoesNotImplyCancellation() {
        XCTAssertEqual(InstallQueue.phaseAfterStoppingMonitoring(hasHandedOff: true), .unconfirmed)
        XCTAssertEqual(InstallQueue.phaseAfterStoppingMonitoring(hasHandedOff: false), .cancelled)
        XCTAssertEqual(presentation(.ready, taskPhase: .unconfirmed), .unconfirmed)
    }
}
