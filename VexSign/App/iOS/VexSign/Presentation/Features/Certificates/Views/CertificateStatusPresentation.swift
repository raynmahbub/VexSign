import SwiftUI
import NimbleExtensions

extension CertificateStatusValue {
	var title: String {
		switch self {
		case .signed:
			String.localized("Signed")
		case .revoked:
			String.localized("Revoked")
		case .unknown:
			String.localized("Unknown")
		}
	}

	var icon: String {
		switch self {
		case .signed:
			"checkmark.seal"
		case .revoked:
			"xmark.octagon"
		case .unknown:
			"questionmark.circle"
		}
	}

	var color: Color {
		switch self {
		case .signed:
			.green
		case .revoked:
			.red
		case .unknown:
			.secondary
		}
	}

}

// MARK: - Status colour

extension CertificateStatus {
	var color: Color {
		switch self {
		case .valid: .green
		case .expired, .revoked: .red
		case .networkUnavailable: .orange
		case .unknown, .unsupported: .secondary
		}
	}
}


extension CertificateRevocationSnapshot {
	/// Short label for a badge. `detail` is a sentence and would not fit.
	var displayTitle: String {
		switch status {
		case .signed: String.localized("OCSP Verified")
		case .revoked: String.localized("Revoked")
		case .unknown: String.localized("Unknown")
		}
	}

}
