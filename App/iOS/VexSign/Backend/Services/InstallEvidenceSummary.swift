//
//  InstallEvidenceSummary.swift
//  VexSign
//
//  What a finished or stopped install attempt is known to have reached, kept as separate
//  facts so that delivering a package, handing it to iOS and the device confirming it are
//  never read as one thing.
//
//  Derived only from what the task record already holds: the method, whether a handoff was
//  recorded, and the reason code the installer wrote. Nothing here asks the device.
//
//  An over-the-air install has no completion callback. The installer asks the device
//  whether the app appeared; when the device does not answer, the attempt ends as
//  "not available", which is neither a success nor a rejection. Only the paired-device
//  method returns the device's own acknowledgement.
//

import Foundation

struct InstallEvidenceSummary: Equatable {
	/// How the package was sent.
	enum Transport: String, Equatable {
		case overTheAir = "over-the-air"
		case pairedDevice = "paired-device"
		case guestImport = "guest-import"
		case export = "export"
		case unknown = "not-recorded"
	}

	/// Whether the request reached iOS or the device.
	enum Handoff: String, Equatable {
		/// The install request was opened or the device command was started.
		case recorded = "recorded"
		/// Nothing was handed over before the attempt ended.
		case notReached = "not-reached"
		/// The method has no handoff to iOS (export, guest import).
		case notApplicable = "not-applicable"
	}

	/// What is known about the app being on the device.
	enum Confirmation: String, Equatable {
		/// The device acknowledged the install or reported the app.
		case confirmed = "confirmed-by-device"
		/// The device reported a different version from the one sent.
		case otherVersion = "device-reports-other-version"
		/// The device was asked and did not report the app.
		case notReported = "device-did-not-report-app"
		/// No start was observed after the prompt.
		case notStarted = "start-not-observed"
		/// No source could say either way.
		case unavailable = "not-available"
		/// The method never installs on the device.
		case notApplicable = "not-applicable"
		/// The attempt failed or was cancelled before there was anything to confirm.
		case notReached = "not-reached"
	}

	/// Whether a source that could confirm the install existed for this attempt.
	enum Verification: String, Equatable {
		/// The paired device answers for itself.
		case deviceAcknowledgement = "device-acknowledgement"
		/// The app was looked up on the device.
		case deviceLookup = "device-lookup"
		/// The device was asked and gave no usable answer before the time limit.
		case deviceDidNotAnswer = "device-lookup-unanswered"
		/// The device was never asked: the attempt ended first, or no lookup was available.
		case unavailable = "not-performed"
		case notApplicable = "not-applicable"
	}

	/// What starting the install again would risk.
	enum RetrySafety: String, Equatable {
		/// Nothing was handed over, so a retry repeats nothing.
		case safe = "safe"
		/// The request reached iOS and the result is unknown: the app may already be
		/// installed, so the device should be checked first.
		case checkDeviceFirst = "check-device-first"
		/// The install is confirmed; a retry would reinstall.
		case notNeeded = "not-needed"
		case notApplicable = "not-applicable"
	}

	let transport: Transport
	let handoff: Handoff
	let confirmation: Confirmation
	let verification: Verification
	let retrySafety: RetrySafety

	/// True when the outcome is unknown and the package may already be installed. A retry
	/// in this state must be started by the user, never automatically.
	var isOutcomeUnknown: Bool { retrySafety == .checkDeviceFirst }

	// MARK: Derivation

	/// - Parameters:
	///   - method: `TaskContext.installationMethod`.
	///   - reason: `TaskContext.confirmationReason`.
	///   - handedOff: whether a handoff time was recorded for the attempt.
	static func resolve(method: String?, reason: String?, handedOff: Bool) -> InstallEvidenceSummary {
		let transport: Transport
		switch method {
		case "OTA": transport = .overTheAir
		case "paired-device": transport = .pairedDevice
		case "guest-import": transport = .guestImport
		case "export": transport = .export
		default: transport = .unknown
		}

		if transport == .export || transport == .guestImport {
			return InstallEvidenceSummary(
				transport: transport, handoff: .notApplicable, confirmation: .notApplicable,
				verification: .notApplicable, retrySafety: .notApplicable
			)
		}

		let confirmation: Confirmation
		switch reason {
		case "native-installation-completed", "device-confirmed-installed":
			confirmation = .confirmed
		case "device-reports-other-version":
			confirmation = .otherVersion
		case "device-did-not-report-installed-app":
			confirmation = .notReported
		case "install-start-not-observed":
			confirmation = .notStarted
		case "supported-installation-inventory-unavailable", "ota-completion-not-authoritative",
			 "installation-evidence-unavailable", "installation-monitoring-deadline",
			 "monitoring-stopped-install-may-continue", "process-exit-installation-unconfirmed":
			confirmation = .unavailable
		default:
			confirmation = .notReached
		}

		// A reason that can only be written after the package was delivered proves the
		// handoff even when its time was not recorded.
		let deliveredReasons: Set<String> = [
			"native-installation-completed", "device-confirmed-installed", "device-reports-other-version",
			"supported-installation-inventory-unavailable", "ota-completion-not-authoritative"
		]
		let handoff: Handoff = handedOff || reason.map({ deliveredReasons.contains($0) }) == true ? .recorded : .notReached

		let verification: Verification
		switch (transport, confirmation) {
		case (.pairedDevice, _):
			verification = .deviceAcknowledgement
		case (_, .confirmed), (_, .otherVersion), (_, .notReported):
			verification = .deviceLookup
		default:
			// These reasons are written by the watcher after it asked the device.
			let asked: Set<String> = [
				"install-start-not-observed", "installation-evidence-unavailable", "installation-monitoring-deadline"
			]
			verification = reason.map({ asked.contains($0) }) == true ? .deviceDidNotAnswer : .unavailable
		}

		let retrySafety: RetrySafety
		switch confirmation {
		case .confirmed:
			retrySafety = .notNeeded
		case .notApplicable:
			retrySafety = .notApplicable
		case .otherVersion, .notReported, .notStarted, .unavailable, .notReached:
			retrySafety = handoff == .recorded ? .checkDeviceFirst : .safe
		}

		return InstallEvidenceSummary(
			transport: transport, handoff: handoff, confirmation: confirmation,
			verification: verification, retrySafety: retrySafety
		)
	}

	/// Fixed-vocabulary lines for a receipt. No names, identifiers or paths.
	var receiptLines: [String] {
		[
			"Installation transport: " + transport.rawValue,
			"Installation handoff: " + handoff.rawValue,
			"Installation confirmation: " + confirmation.rawValue,
			"Verification source: " + verification.rawValue,
			"Retry safety: " + retrySafety.rawValue
		]
	}
}

// MARK: - Retry

/// Whether an install may be started again. A retry is always the user's action; this only
/// decides whether that action can go ahead.
enum InstallRetryPolicy {
	enum Refusal: Equatable {
		/// The signed copy is no longer in the library, so there is nothing to send.
		case signedCopyMissing
		/// The same copy is already being installed.
		case alreadyInstalling
	}

	/// - Parameters:
	///   - signedCopyPresent: the bundle that would be sent still exists on disk.
	///   - duplicateInFlight: another attempt for the same copy is running.
	static func refusal(signedCopyPresent: Bool, duplicateInFlight: Bool) -> Refusal? {
		if duplicateInFlight { return .alreadyInstalling }
		if !signedCopyPresent { return .signedCopyMissing }
		return nil
	}
}
