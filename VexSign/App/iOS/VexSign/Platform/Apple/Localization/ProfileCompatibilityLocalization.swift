import Foundation
import NimbleExtensions

extension ProfileCompatibility.Verdict {
		var title: String {
			switch self {
			case .covers:
				.localized("Signs this app")
			case .wildcard:
				.localized("Wildcard · signs this app")
			case .unusable:
				.localized("Can't sign this app")
			case .unknown:
				.localized("Unknown")
			}
		}
}
