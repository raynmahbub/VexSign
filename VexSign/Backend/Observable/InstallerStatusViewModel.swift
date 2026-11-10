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
