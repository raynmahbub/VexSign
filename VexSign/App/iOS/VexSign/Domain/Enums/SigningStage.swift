import Foundation

/// Stable persisted stage identifiers. Append only; never rename the raw values.
enum SigningStage: String, CaseIterable, Codable, Sendable {
	case copying
	case modifying
	case thinning
	case injecting
	case signing
	case verifying
	case registering

	/// Where the run is, for a determinate progress indicator. Ordered, so a progress bar only
	/// ever moves forwards.
	var progress: Double {
		switch self {
		case .copying:
			0.10
		case .modifying:
			0.25
		case .thinning:
			0.40
		case .injecting:
			0.55
		case .signing:
			0.70
		case .verifying:
			0.85
		case .registering:
			0.95
		}
	}
}
