import Foundation
import NimbleExtensions

extension SigningCapabilityStatus {
	/// A sentence for a badge or a summary row.
	var title: String {
		switch self {
		case .supported: .localized("Ready")
		case .requiresAction: .localized("Needs your input")
		case .ambiguous: .localized("Check before signing")
		case .incompatible: .localized("Not compatible")
		case .invalid: .localized("Not usable")
		case .expired: .localized("Expired")
		case .unsupported: .localized("Not supported")
		}
	}
}

extension SigningCapability.Refusal: LocalizedError {
		var errorDescription: String? {
			let reasons = issues.map { issue in
				issue.remediation.map { "\(issue.detail) \($0)" } ?? issue.detail
			}
			return .localized("Signing was not started. %@", arguments: reasons.joined(separator: " "))
		}
}

extension SigningCapability {
	/// The sentence to put in front of the user when the run cannot start.
	var summary: String {
		guard let first = blocking.first else {
			return status.title
		}
		return first.remediation.map { "\(first.detail) \($0)" } ?? first.detail
	}

}
