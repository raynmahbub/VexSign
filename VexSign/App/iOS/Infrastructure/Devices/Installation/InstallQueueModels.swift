//
//  InstallQueueModels.swift
//  VexSign
//
//  Shared model types for the installation queue.
//

import Foundation
import NimbleExtensions

// MARK: - Failure Presentation

/// Which of four different situations an installer failure actually is.
///
/// They used to collapse into two, which produced two wrong reports: a genuine failure (no
/// pairing file, a broken server) told the user the app "may already be installed", and an
/// install that never started was titled "Installation Not Confirmed" as though iOS had been
/// asked and stayed silent. Separating them is what makes the recovery text actionable.
extension InstallQueue {
	enum FailureKind: Equatable {
	    /// Local HTTPS could not be verified; the fix is trusting the certificate, not retrying.
	    case needsTrust
	    /// iOS was asked and nothing was ever served. No bytes reached the device.
	    case neverStarted
	    /// VexSign finished, but iOS never exposed enough evidence to say either way.
	    case unconfirmed
	    /// The installer reported a real failure.
	    case failed

	    static func resolve(error: Error, needsTrust: Bool) -> FailureKind {
	        if needsTrust { return .needsTrust }
	        switch (error as? InstallConfirmation.Failure)?.verdict {
	        case .some(.timedOutVerifying), .some(.notInstalled), .some(.installedOtherVersion): return .unconfirmed
	        case .some(.timedOutWaiting): return .unconfirmed
	        default: return .failed
	        }
	    }

	    var title: String {
	        switch self {
	        case .needsTrust: return .localized("HTTPS Setup Required")
	        case .neverStarted: return .localized("Install Never Started")
	        case .unconfirmed: return .localized("Installation Not Confirmed")
	        case .failed: return .localized("Install Failed")
	        }
	    }

	    /// What the user can do next. Never a diagnosis of what iOS decided.
	    var summary: String {
	        switch self {
	        case .needsTrust:
	            return .localized("Local HTTPS verification failed. Check the identity in Settings → Installation → Server & SSL, export and install its Root CA profile, then enable Full Trust in iOS Certificate Trust Settings.")
	        case .neverStarted:
	            return .localized("The installation never started, so nothing was sent to iOS. Keep VexSign in the foreground and retry; if iOS never showed its prompt, review the installation method in Settings.")
	        case .unconfirmed:
	            return .localized("VexSign could not confirm installation. If the app is already on your Home Screen, it may already be installed. Review the details below before retrying.")
	        case .failed:
	            return .localized("Installation failed. Review the details below, then retry.")
	        }
	    }

	    /// Whether this is recorded on the task as a failure. An unconfirmed install is not one:
	    /// the device was never heard from either way, and recording a failure it did not report
	    /// is what told users to reinstall an app that was already on their Home Screen.
	    var recordsFailure: Bool { self != .unconfirmed }

	    /// A previous handoff may still have installed the app. Retrying is offered only
	    /// after the user explicitly confirms they checked the device.
	    var requiresDeviceCheckBeforeRetry: Bool { self == .unconfirmed }

	    /// How the unified task record ends.
	    var taskPhase: UnifiedTaskPhase { self == .unconfirmed ? .unconfirmed : .failed }

	    /// Whether the sheet is released rather than held. Only an unconfirmed outcome does that:
	    /// every other kind has a recovery action the user needs to see.
	    var releasesSheet: Bool { self == .unconfirmed }
	}
}

// MARK: - Outcome

/// Per-entry outcome, keyed by the entry's id, so the queue list view can show what happened.
extension InstallQueue {
	enum InstallOutcome: Equatable {
		case pending
		case succeeded
		case guestPrepared
	    case unconfirmed
		case failed(String)
		case skipped

		func canOpenApp(isExport: Bool, identifier: String?) -> Bool {
			self == .succeeded && !isExport && !(identifier ?? "").isEmpty
		}
	}
}

// MARK: - Failure Presentation

extension InstallQueue {
	struct FailurePresentation: Identifiable {
	    let id = UUID()
	    let title: String
	    let message: String
	    let details: String
	    let needsTrust: Bool
	    let canRetryLocally: Bool
	    let requiresDeviceCheckBeforeRetry: Bool
	    let waitingCount: Int
	}
}