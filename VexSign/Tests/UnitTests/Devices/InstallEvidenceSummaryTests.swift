//
//  InstallEvidenceSummaryTests.swift
//  VexSignTests
//
//  Delivery, handoff and confirmation are separate facts. These tests pin what each
//  recorded outcome is allowed to claim, and that a single history record can be removed
//  without touching anything that is still running.
//

import XCTest
@testable import VexSign

final class InstallEvidenceSummaryTests: XCTestCase {
	private func resolve(_ method: String?, _ reason: String?, handedOff: Bool = false) -> InstallEvidenceSummary {
		InstallEvidenceSummary.resolve(method: method, reason: reason, handedOff: handedOff)
	}

	// MARK: - Over the air

	/// The reported receipt: the package was served and nothing can say what iOS did with it.
	func testAnOverTheAirDeliveryIsNotAConfirmedInstall() {
		let summary = resolve("OTA", "supported-installation-inventory-unavailable")

		XCTAssertEqual(summary.transport, .overTheAir)
		XCTAssertEqual(summary.handoff, .recorded, "this reason is only written after the package was delivered")
		XCTAssertEqual(summary.confirmation, .unavailable)
		XCTAssertEqual(summary.verification, .unavailable)
		XCTAssertEqual(summary.retrySafety, .checkDeviceFirst)
		XCTAssertTrue(summary.isOutcomeUnknown)
	}

	func testTheServerFinishingIsNotAConfirmationEither() {
		let summary = resolve("OTA", "ota-completion-not-authoritative", handedOff: true)
		XCTAssertEqual(summary.confirmation, .unavailable)
		XCTAssertNotEqual(summary.confirmation, .confirmed)
		XCTAssertTrue(summary.isOutcomeUnknown)
	}

	func testAnAttemptThatNeverReachedIOSIsSafeToRetry() {
		for reason in ["operation-failed", "preparation-cancelled", "cancelled", nil] as [String?] {
			let summary = resolve("OTA", reason)
			XCTAssertEqual(summary.handoff, .notReached, String(describing: reason))
			XCTAssertEqual(summary.confirmation, .notReached, String(describing: reason))
			XCTAssertEqual(summary.retrySafety, .safe, String(describing: reason))
			XCTAssertFalse(summary.isOutcomeUnknown)
		}
	}

	func testAFailureAfterHandoffIsNotCalledSafe() {
		let summary = resolve("OTA", "operation-failed", handedOff: true)
		XCTAssertEqual(summary.handoff, .recorded)
		XCTAssertEqual(summary.retrySafety, .checkDeviceFirst)
	}

	func testADeviceThatDidNotAnswerIsReportedAsAskedButUnanswered() {
		for reason in ["installation-evidence-unavailable", "install-start-not-observed", "installation-monitoring-deadline"] {
			let summary = resolve("OTA", reason, handedOff: true)
			XCTAssertEqual(summary.verification, .deviceDidNotAnswer, reason)
			XCTAssertNotEqual(summary.confirmation, .confirmed, reason)
			XCTAssertTrue(summary.isOutcomeUnknown, reason)
		}
	}

	func testStoppingMonitoringLeavesTheOutcomeUnknown() {
		let summary = resolve("OTA", "monitoring-stopped-install-may-continue", handedOff: true)
		XCTAssertEqual(summary.confirmation, .unavailable)
		XCTAssertTrue(summary.isOutcomeUnknown)
	}

	func testADeviceLookupThatFoundTheAppConfirmsIt() {
		let summary = resolve("OTA", "device-confirmed-installed", handedOff: true)
		XCTAssertEqual(summary.confirmation, .confirmed)
		XCTAssertEqual(summary.verification, .deviceLookup)
		XCTAssertEqual(summary.retrySafety, .notNeeded)
		XCTAssertFalse(summary.isOutcomeUnknown)
	}

	func testAnotherVersionOnTheDeviceIsNotAConfirmation() {
		let summary = resolve("OTA", "device-reports-other-version", handedOff: true)
		XCTAssertEqual(summary.confirmation, .otherVersion)
		XCTAssertEqual(summary.retrySafety, .checkDeviceFirst)
	}

	// MARK: - Other methods

	func testThePairedDeviceAcknowledgementIsAConfirmation() {
		let summary = resolve("paired-device", "native-installation-completed")
		XCTAssertEqual(summary.transport, .pairedDevice)
		XCTAssertEqual(summary.handoff, .recorded)
		XCTAssertEqual(summary.confirmation, .confirmed)
		XCTAssertEqual(summary.verification, .deviceAcknowledgement)
		XCTAssertEqual(summary.retrySafety, .notNeeded)
	}

	func testExportAndGuestImportClaimNothingAboutTheDevice() {
		for method in ["export", "guest-import"] {
			let summary = resolve(method, method == "export" ? "exported-not-installed" : "guest-prepared-not-installed")
			XCTAssertEqual(summary.handoff, .notApplicable, method)
			XCTAssertEqual(summary.confirmation, .notApplicable, method)
			XCTAssertEqual(summary.retrySafety, .notApplicable, method)
			XCTAssertFalse(summary.isOutcomeUnknown, method)
		}
	}

	func testAnUnknownMethodIsNotGuessed() {
		XCTAssertEqual(resolve(nil, nil).transport, .unknown)
		XCTAssertEqual(resolve("something-else", nil).transport, .unknown)
	}

	// MARK: - Receipt

	private func installTask(method: String, reason: String, phase: UnifiedTaskPhase) -> UnifiedTask {
		let task = UnifiedTask(kind: .install, title: "App", phase: .preparingInstallation)
		task.context?.installationMethod = method
		task.context?.confirmationReason = reason
		task.phase = phase
		return task
	}

	func testTheReceiptCarriesEachStageOnItsOwnLine() {
		let report = TaskReceipt.report(
			for: installTask(method: "OTA", reason: "supported-installation-inventory-unavailable", phase: .unconfirmed)
		)

		XCTAssertTrue(report.contains("Installation transport: over-the-air"), report)
		XCTAssertTrue(report.contains("Installation handoff: recorded"), report)
		XCTAssertTrue(report.contains("Installation confirmation: not-available"), report)
		XCTAssertTrue(report.contains("Verification source: not-performed"), report)
		XCTAssertTrue(report.contains("Retry safety: check-device-first"), report)
		XCTAssertFalse(report.contains("confirmed-by-device"), report)
	}

	func testARunningInstallDoesNotReportStagesItHasNotFinished() {
		let task = UnifiedTask(kind: .install, title: "App", phase: .preparingInstallation)
		task.context?.installationMethod = "OTA"
		XCTAssertFalse(TaskReceipt.report(for: task).contains("Installation confirmation:"))
	}

	func testOnlyInstallReceiptsCarryTheStageLines() {
		let task = UnifiedTask(kind: .sign, title: "App", phase: .signing)
		task.phase = .completed
		XCTAssertFalse(TaskReceipt.report(for: task).contains("Installation transport:"))
	}

	func testAnUnconfirmedOverTheAirReceiptExplainsWhyThereIsNoAnswer() {
		let ota = installTask(method: "OTA", reason: "supported-installation-inventory-unavailable", phase: .unconfirmed)
		let other = installTask(method: "paired-device", reason: "installation-monitoring-deadline", phase: .unconfirmed)
		XCTAssertNotEqual(TaskReceipt.outcome(for: ota), TaskReceipt.outcome(for: other))
	}

	// MARK: - Removing one history record

	private func record(_ id: String, _ phase: UnifiedTaskPhase) -> UnifiedTask {
		let task = UnifiedTask(id: id, kind: .download, title: id, phase: .downloading)
		task.phase = phase
		return task
	}

	func testRemovingARecordRemovesOnlyThatRecord() throws {
		let records = [record("a", .completed), record("b", .failed), record("c", .cancelled)]
		let remaining = try XCTUnwrap(UnifiedTaskCenter.history(records, removing: "b"))
		XCTAssertEqual(remaining.map(\.id), ["a", "c"])
	}

	func testRemovalIsByIdentifierNotPosition() throws {
		let records = [record("c", .completed), record("a", .completed), record("b", .completed)]
		let remaining = try XCTUnwrap(UnifiedTaskCenter.history(records, removing: "a"))
		XCTAssertEqual(remaining.map(\.id), ["c", "b"])
	}

	func testAnUnknownIdentifierRemovesNothing() {
		XCTAssertNil(UnifiedTaskCenter.history([record("a", .completed)], removing: "missing"))
		XCTAssertNil(UnifiedTaskCenter.history([], removing: "a"))
	}

	func testARecordThatIsStillRunningIsNeverRemoved() {
		XCTAssertNil(UnifiedTaskCenter.history([record("a", .downloading)], removing: "a"))
	}

	func testRemovingTwiceIsHarmless() throws {
		let once = try XCTUnwrap(UnifiedTaskCenter.history([record("a", .completed), record("b", .completed)], removing: "a"))
		XCTAssertNil(UnifiedTaskCenter.history(once, removing: "a"), "a second swipe on the same row finds nothing to remove")
		XCTAssertEqual(once.map(\.id), ["b"])
	}

	// MARK: - Undo

	func testARemovedRecordIsRestoredInDateOrder() throws {
		let newest = record("new", .completed)
		let middle = record("mid", .completed)
		let oldest = record("old", .completed)
		newest.updatedAt = Date()
		middle.updatedAt = Date().addingTimeInterval(-60)
		oldest.updatedAt = Date().addingTimeInterval(-120)

		let removed = try XCTUnwrap(UnifiedTaskCenter.history([newest, middle, oldest], removing: "mid"))
		let restored = try XCTUnwrap(UnifiedTaskCenter.history(removed, restoring: middle))
		XCTAssertEqual(restored.map(\.id), ["new", "mid", "old"])
		XCTAssertTrue(restored[1] === middle, "the same record returns, not a copy")
	}

	func testUndoCannotDuplicateARecord() {
		let task = record("a", .completed)
		XCTAssertNil(UnifiedTaskCenter.history([task], restoring: task))
	}

	func testARunningRecordIsNeverPutIntoHistory() {
		XCTAssertNil(UnifiedTaskCenter.history([], restoring: record("a", .downloading)))
	}

	// MARK: - Retry

	func testRetryNeedsTheSignedCopyAndNoDuplicate() {
		XCTAssertNil(InstallRetryPolicy.refusal(signedCopyPresent: true, duplicateInFlight: false))
		XCTAssertEqual(InstallRetryPolicy.refusal(signedCopyPresent: false, duplicateInFlight: false), .signedCopyMissing)
		XCTAssertEqual(InstallRetryPolicy.refusal(signedCopyPresent: true, duplicateInFlight: true), .alreadyInstalling)
		XCTAssertEqual(InstallRetryPolicy.refusal(signedCopyPresent: false, duplicateInFlight: true), .alreadyInstalling)
	}
}
