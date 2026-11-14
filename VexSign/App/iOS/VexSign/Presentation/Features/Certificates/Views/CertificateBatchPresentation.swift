import SwiftUI
import NimbleExtensions

extension CertCheckResult {
	var statusTitle: String {
		switch status {
		case .valid: String.localized("Valid")
		case .expiringSoon: String.localized("Expiring Soon")
		case .expired: String.localized("Expired")
		case .revoked: String.localized("Revoked")
		case .unreadable: String.localized("Unreadable")
		case .notChecked: String.localized("Not Checked")
		}
	}

	var statusColor: Color {
		switch status {
		case .valid: .green
		case .expiringSoon: .orange
		case .expired: .red
		case .revoked: .red
		case .unreadable: .secondary
		case .notChecked: .secondary
		}
	}

	var statusIcon: String {
		switch status {
		case .valid: "checkmark.seal.fill"
		case .expiringSoon: "clock.badge.exclamationmark"
		case .expired: "xmark.seal.fill"
		case .revoked: "xmark.octagon.fill"
		case .unreadable: "questionmark.circle"
		case .notChecked: "questionmark.circle"
		}
	}

}
