//
//  InstallStatusPresentationTests.swift
//  VexSignTests
//
//  The install card's status line, as a table of transport status against install lifecycle.
//
//  The defect this pins down: `InstallCardView` resolved its line with
//
//      guard case .installing = viewModel.status else { return viewModel.statusLabel }
//
//  so the lifecycle was only consulted on one transport status. In the OTA path the transport
//  reports `.ready` when the local server can serve and says nothing more until iOS answers its
//  prompt — exactly the window in which the card read "Ready" while iOS was asking the user to
//  install. A green signing pipeline is irrelevant to that: nothing was wrong with the install,
//  only with what the screen claimed about it.
//

import Foundation
import IDeviceSwift
import NimbleExtensions
import XCTest
@testable import VexSign

final class InstallStatusPresentationTests: XCTestCase {
	private func resolve(
		_ transport: InstallerStatusViewModel.InstallerStatus,
		_ phase: InstallConfirmation.Phase,
		attempt: Int = 0,
		progress: Double = 0,
		isCompleted: Bool = false
	) -> InstallStatusPresentation {
		InstallStatusPresentation.resolve(
			transport: transport,
			phase: phase,
			verificationAttempt: attempt,
			overallProgress: progress,
			isCompleted: isCompleted
		)
	}

	private var transportStatuses: [InstallerStatusViewModel.InstallerStatus] {
		[
			.none,
			.ready,
			.sendingManifest,
			.sendingPayload,
			.installing,
			.completed(.success(())),
			.broken(NSError(domain: "test", code: 1))
		]
	}

	// MARK: - The reported defect

	func testWaitingForIOSConfirmationIsNotShownAsReady() {
		// The moment the OTA server comes up: iOS's own prompt is on screen, the transport has
		// nothing else to report, and the lifecycle knows an install is waiting to start.
		let presentation = resolve(.ready, .waitingForStart)
		XCTAssertEqual(presentation.label, String.localized("Waiting for iOS installation"))
		XCTAssertNotEqual(presentation.label, InstallerStatusViewModel.label(for: .ready),
						 "The server being ready is not the installation being asked for")
	}

	func testTheWaitingLineIsUsedForEveryTransportThatHasNoInstallActivity() {
		// `.none` (still packaging locally), `.ready` (prompt open) and `.sendingManifest` all
		// mean the device has not begun installing. Only `.ready` is relabelled, because the
		// other two describe work the user can see VexSign doing.
		XCTAssertEqual(resolve(.none, .waitingForStart).label, InstallerStatusViewModel.label(for: .none))
		XCTAssertEqual(resolve(.sendingManifest, .waitingForStart).label,
					   InstallerStatusViewModel.label(for: .sendingManifest))
		XCTAssertEqual(resolve(.sendingPayload, .waitingForStart).label,
					   InstallerStatusViewModel.label(for: .sendingPayload))
	}

	func testNoOpenTransportStatusCanPutReadyOnAStartedInstall() {
		for transport in transportStatuses {
			let label = self.resolve(transport, .waitingForStart).label
			XCTAssertNotEqual(label, String.localized("Ready"),
							  "\(transport) put 'Ready' on an install the user is being asked to confirm")
		}
	}

	// MARK: - Verification outranks the transport

	func testVerificationIsShownWhateverTheTransportLastSaid() {
		let first = InstallVerificationPolicy.statusLabel(attempt: 1)
		for transport in [.ready, .sendingPayload, .installing, .none] as [InstallerStatusViewModel.InstallerStatus] {
			XCTAssertEqual(resolve(transport, .verifying).label, first,
						   "\(transport) hid the device check behind a stale transport status")
		}
	}

	func testVerificationShowsItsAttemptCount() {
		let presentation = resolve(.installing, .verifying, attempt: 4)
		XCTAssertEqual(presentation.label, InstallVerificationPolicy.statusLabel(attempt: 4))
		XCTAssertTrue(presentation.label.contains("4"), "a verification still asking has to look like it is moving")
	}

	// MARK: - Progress is the installation

	func testACounterMakesTheCardSayInstallingEvenWhileThePayloadIsStillServed() {
		let presentation = resolve(.sendingPayload, .downloading, progress: 0.42)
		XCTAssertEqual(presentation.label, String.localized("Installing"))
		XCTAssertEqual(presentation.percentage, 42)
	}

	func testThePercentageIsNeverManufactured() {
		XCTAssertNil(resolve(.ready, .waitingForStart, progress: 0.4).percentage)
		XCTAssertNil(resolve(.installing, .verifying, attempt: 2, progress: 0.99).percentage,
					 "verification deliberately holds below 1.0")
		XCTAssertEqual(resolve(.installing, .downloading, progress: 0.42).percentage, 42)
		XCTAssertEqual(resolve(.completed(.success(())), .finished(.installed), isCompleted: true).percentage, 100)
	}

	// MARK: - Terminal answers win

	func testAFailureIsNeverDressedAsProgress() {
		let error = NSError(domain: "test", code: 2)
		for phase in [InstallConfirmation.Phase.waitingForStart, .downloading, .verifying, .finished(.installed)] {
			let presentation = resolve(.broken(error), phase, progress: 0.3)
			XCTAssertEqual(presentation.label, InstallerStatusViewModel.label(for: .broken(error)))
			XCTAssertEqual(presentation.systemImage, InstallerStatusViewModel.image(for: .broken(error)))
		}
	}

	func testCompletedIsOnlyTheDeviceProvedAnswer() {
		let presentation = resolve(.completed(.success(())), .waitingForStart)
		XCTAssertEqual(presentation.label, String.localized("Installed"))
		XCTAssertEqual(presentation.systemImage, "app.badge.checkmark")
		XCTAssertNotEqual(presentation.label, String.localized("Completed"),
						  "the transport completing is the install the device proved, not a transfer")
	}

	func testACompletionCarryingAFailureIsNotAnInstalledAnswer() {
		let failed = InstallerStatusViewModel.InstallerStatus.completed(
			.failure(NSError(domain: "test", code: 3))
		)
		let presentation = resolve(failed, .waitingForStart)
		XCTAssertEqual(presentation.label, String.localized("Error"))
		XCTAssertNotEqual(presentation.systemImage, "app.badge.checkmark")
	}

	func testAnUnconfirmedInstallIsNotReportedAsReadyOrInstalled() {
		let presentation = resolve(.ready, .finished(.timedOutVerifying))
		XCTAssertEqual(presentation.label, String.localized("Not confirmed"))
		XCTAssertNotEqual(presentation.label, String.localized("Ready"))
		XCTAssertNotEqual(presentation.label, String.localized("Installed"))
	}

	func testAnUnansweredPromptIsNotReportedAsAnUnconfirmedInstall() {
		// "Nothing was installed" and "iOS never said" are different failures with different
		// recovery, so they must not share a card label.
		XCTAssertNotEqual(
			resolve(.ready, .finished(.timedOutWaiting)).label,
			resolve(.ready, .finished(.timedOutVerifying)).label
		)
	}

	func testEveryVerdictHasItsOwnWording() {
		let verdicts: [InstallConfirmation.Verdict] = [
			.installed,
			.installedOtherVersion("2.0"),
			.cancelled,
			.notInstalled,
			.timedOutWaiting,
			.timedOutVerifying
		]
		let labels = verdicts.map { resolve(.ready, .finished($0)).label }
		XCTAssertEqual(Set(labels).count, 4, "only the proven-install verdicts may share wording: \(labels)")
	}

	// MARK: - Icons follow the same rule

	func testTheWaitingAndVerifyingIconsAreNotTheReadyGift() {
		XCTAssertNotEqual(resolve(.ready, .waitingForStart).systemImage,
						  InstallerStatusViewModel.image(for: .ready))
		XCTAssertEqual(resolve(.ready, .verifying).systemImage, "checkmark.shield")
	}

	func testTheTransportIconIsKeptWhileItIsTheMoreSpecificAnswer() {
		XCTAssertEqual(resolve(.sendingPayload, .waitingForStart).systemImage,
					   InstallerStatusViewModel.image(for: .sendingPayload))
		XCTAssertEqual(resolve(.none, .waitingForStart).systemImage,
					   InstallerStatusViewModel.image(for: .none))
	}

	// MARK: - The model still answers for its transport alone

	func testTheModelKeepsTheTransportWordingAvailable() {
		// `InstallStatusPresentation` needs both halves; anything that legitimately wants only
		// the transport's own answer keeps getting it from the same table.
		for status in transportStatuses {
			let model = InstallerStatusViewModel(status: status, isIdevice: false)
			XCTAssertEqual(model.statusLabel, InstallerStatusViewModel.label(for: status))
			XCTAssertEqual(model.statusImage, InstallerStatusViewModel.image(for: status))
		}
	}
}
