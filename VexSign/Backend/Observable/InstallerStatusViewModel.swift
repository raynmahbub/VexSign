//
//  StatusViewModel.swift
//  VexSign
//
//  Created by VexSign TeamSign Team on 24.04.2025.
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
        return Int((overall * 100).rounded())
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

	var statusImage: String {
		switch status {
		case .none: "archivebox.fill"
		case .ready: "app.gift"
		case .sendingManifest, .sendingPayload: "paperplane.fill"
		case .installing: "square.and.arrow.down"
		case .completed: "app.badge.checkmark"
		case .broken: "exclamationmark.triangle.fill"
		}
	}
	
	var statusLabel: String {
		switch status {
		case .none: .localized("Packaging")
		case .ready: .localized("Ready")
		case .sendingManifest: .localized("Sending Manifest")
		case .sendingPayload: .localized("Sending Payload")
		case .installing: .localized("Installing")
		case .completed: .localized("Completed")
		case .broken: .localized("Error")
		}
	}
}


/// A presentation of existing transport and confirmation state, not another install lifecycle.
/// The same projection is used by the card, its accessibility label, and batch rows.
enum InstallPresentation: Equatable {
    case preparing, awaitingConfirmation, sendingManifest, installing, verifying
    case installed, unconfirmed, failed, operationCompleted

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

    func label(verificationAttempt: Int = 0) -> String {
        switch self {
        case .preparing: return .localized("Preparing")
        case .awaitingConfirmation: return .localized("Waiting for iOS confirmation")
        case .sendingManifest: return .localized("Sending installation manifest")
        case .installing: return .localized("Installing")
        case .verifying: return InstallVerificationPolicy.statusLabel(attempt: verificationAttempt)
        case .installed: return .localized("Installed")
        case .unconfirmed: return .localized("Installation not confirmed")
        case .failed: return .localized("Installation error")
        case .operationCompleted: return .localized("Completed")
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .verifying: return .localized("Verifying installation")
        case .installed: return .localized("Installation completed")
        case .failed: return .localized("Installation failed")
        default: return label()
        }
    }

    var symbol: String {
        switch self {
        case .preparing: return "archivebox.fill"
        case .awaitingConfirmation: return "clock"
        case .sendingManifest: return "paperplane.fill"
        case .installing: return "square.and.arrow.down"
        case .verifying: return "magnifyingglass"
        case .installed, .operationCompleted: return "checkmark.circle.fill"
        case .unconfirmed: return "questionmark.circle"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    var isTerminal: Bool {
        switch self {
        case .installed, .unconfirmed, .failed, .operationCompleted: return true
        default: return false
        }
    }
}
