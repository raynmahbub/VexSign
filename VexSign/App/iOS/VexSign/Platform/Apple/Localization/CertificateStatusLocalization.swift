import Foundation
import NimbleExtensions

// MARK: - Presentation

extension CertificateStatus {
	var title: String {
		switch self {
		case .valid: .localized("Valid")
		case .expired: .localized("Expired")
		case .revoked: .localized("Revoked")
		case .unknown: .localized("Unknown")
		case .networkUnavailable: .localized("Check Unavailable")
		case .unsupported: .localized("Check Unsupported")
		}
	}

	var icon: String {
		switch self {
		case .valid: "checkmark.seal"
		case .expired: "calendar.badge.exclamationmark"
		case .revoked: "xmark.octagon"
		case .unknown: "questionmark.circle"
		case .networkUnavailable: "wifi.slash"
		case .unsupported: "minus.circle"
		}
	}
}

extension CertificateStatusAssessment {
	/// One sentence saying what the status rests on.
	var explanation: String {
		switch reason {
		case .revokedByIssuer:
			.localized("The issuer reports this certificate as revoked. Apps signed with it will not install or open.")
		case .revokedOnRecord:
			.localized("An earlier check found this certificate revoked. Revocation is permanent.")
		case .certificateExpired:
			.localized("The signing certificate has passed its expiry date.")
		case .profileExpired:
			.localized("The provisioning profile has passed its expiry date.")
		case .positiveEvidence:
			.localized("A recent revocation check confirmed this certificate. This does not guarantee that a particular app will install.")
		case .evidenceTooOld:
			.localized("The last successful revocation check is more than a day old, so the current status is not known.")
		case .notChecked:
			.localized("Revocation has not been checked yet. Not having expired does not mean the certificate is valid.")
		case .responderUnreachable:
			.localized("The revocation service could not be reached. This says nothing about the certificate; try again when online.")
		case .revocationUnsupported:
			.localized("A revocation check could not be set up for this certificate on this device.")
		case .inconclusive:
			.localized("The last check ended without an answer about revocation.")
		}
	}
}
