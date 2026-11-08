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
