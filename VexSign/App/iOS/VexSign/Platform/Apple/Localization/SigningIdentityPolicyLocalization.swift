import Foundation
import NimbleExtensions

extension SigningIdentityPolicy.Rejection: LocalizedError {
		var errorDescription: String? { message }

		/// The sentence itself. `errorDescription` is total because every case has one, so
		/// callers that log it do not need a second, unreachable fallback string.
		var message: String {
			switch self {
			case .missingCertificate:
				// "Modify" is the option's own label; naming it here keeps the two screens
				// saying the same thing.
				return .localized(
					"No certificate selected. Choose one in Settings → Certificates, or sign with Modify."
				)
			case .certificateExpired(let expiresAt):
				return .localized(
					"Certificate expired %@ — iOS will refuse to install what it signs.",
					arguments: expiresAt.formatted(date: .abbreviated, time: .omitted)
				)
			case .certificateRevoked:
				return .localized(
					"The selected certificate has been revoked, so anything it signs will be rejected."
				)
			}
		}

}

extension SigningIdentityPolicy {
	/// A sentence for the run's log, so the refusal is visible in the console the user is
	/// already looking at — not only in the alert.
	static func logLine(for rejection: Rejection) -> String {
		rejection.message
	}
}
