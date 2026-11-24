//
//  StatusViewModel.swift
//  VexSign
//
//  Created by VexSign Contributors on 24.04.2025.
//

import Foundation
import Combine
import IDeviceSwift
import NimbleExtensions

extension InstallerStatusViewModel {
    /// The percentage the install card may print, or nil when there is nothing honest to print.
    ///
    /// `waitingForStart` has no counter yet, and `verifying` deliberately holds the ring below
    /// 1.0 until the device answers — printing either as a number would manufacture progress iOS
    /// never reported. The ring keeps animating; only the text is withheld. A confirmed
    /// completion is the one state that is genuinely 100%.
    ///
    /// Pure, so the "never invent a percentage" rule is testable without an installer.
    static func displayedPercentage(
        phase: InstallConfirmation.Phase,
        overall: Double,
        isCompleted: Bool
    ) -> Int? {
        if isCompleted { return 100 }
        guard case .downloading = phase else { return nil }
        guard overall.isFinite, overall > 0, overall < 1 else { return nil }
        return min(99, Int((overall * 100).rounded()))
    }

    @MainActor
    func beginDeviceVerification() {
        installProgress = min(installProgress, 0.99)
        status = .installing
    }

    /// A delayed/repeated payload callback cannot undo a device-confirmed
    /// completion while the card is animating away.
    @MainActor
    func updateTransportStatus(_ status: InstallerStatus) {
        guard !isCompleted else { return }
        self.status = status
    }

	var statusImage: String { Self.image(for: status) }
	
	var statusLabel: String { Self.label(for: status) }

	/// The transport's own wording, without needing a model instance.
	///
	/// Install views combine transport and lifecycle evidence through `InstallPresentation`.
	static func image(for status: InstallerStatus) -> String {
		switch status {
		case .none: "archivebox.fill"
		case .ready: "app.gift"
		case .sendingManifest, .sendingPayload: "paperplane.fill"
		case .installing: "square.and.arrow.down"
		// A failure carried inside a completion is still a failure.
		case .completed(let result):
			switch result {
			case .success: "app.badge.checkmark"
			case .failure: "exclamationmark.triangle.fill"
			}
		case .broken: "exclamationmark.triangle.fill"
		}
	}

	static func label(for status: InstallerStatus) -> String {
		switch status {
		case .none: .localized("Packaging")
		case .ready: .localized("Ready")
		case .sendingManifest: .localized("Sending Manifest")
		case .sendingPayload: .localized("Sending Payload")
		case .installing: .localized("Installing")
		// `.completed(.success)` is published only by `publishConfirmedCompletion`, which runs
		// for an outcome the device proved. "Completed" made the card read as a transfer that
		// finished. A completion carrying a failure says so.
		case .completed(let result):
			switch result {
			case .success: .localized("Installed")
			case .failure: .localized("Error")
			}
		case .broken: .localized("Error")
		}
	}
}


/// A presentation of existing transport and confirmation state, not another install lifecycle.
/// The same projection is used by the card, its accessibility label, and batch rows.
extension InstallPresentation {
    static func resolve(
        status: InstallerStatusViewModel.InstallerStatus,
        phase: InstallConfirmation.Phase,
        taskPhase: UnifiedTaskPhase? = nil,
        isExport: Bool = false
    ) -> Self {
        // A finalized authoritative task outranks a late transport or watcher callback.
        if taskPhase == .unconfirmed || taskPhase == .interrupted { return .unconfirmed }
        if taskPhase == .failed { return .failed }
        if !isExport, case .finished(let verdict) = phase {
            switch verdict {
            case .installed: return .installed
            case .installedOtherVersion, .notInstalled, .timedOutWaiting, .timedOutVerifying, .cancelled:
                return .unconfirmed
            }
        }
        switch status {
        case .broken, .completed(.failure): return .failed
        default: break
        }
        if !isExport {
            switch phase {
            case .verifying: return .verifying
            case .downloading: return .installing
            case .waitingForStart, .finished: break
            }
            // A served manifest can remain the transport status while the system alert is up.
            if taskPhase == .waitingForIOS {
                switch status {
                case .ready, .sendingManifest: return .awaitingConfirmation
                default: break
                }
            }
        }
        switch status {
        case .none: return .preparing
        case .ready: return isExport ? .preparing : .awaitingConfirmation
        case .sendingManifest: return .sendingManifest
        case .sendingPayload, .installing: return .installing
        case .completed(.success): return isExport ? .operationCompleted : .verifying
        case .completed(.failure), .broken: return .failed
        }
    }

}
