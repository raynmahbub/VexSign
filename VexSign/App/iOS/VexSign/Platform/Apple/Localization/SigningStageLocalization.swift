import Foundation
import NimbleExtensions

/// Localized display strings stay outside the framework-independent stage model.
extension SigningStage {
	var title: String {
		switch self {
		case .copying:
			.localized("Copying the bundle")
		case .modifying:
			.localized("Modifying the bundle")
		case .thinning:
			.localized("Thinning binaries")
		case .injecting:
			.localized("Injecting tweaks")
		case .signing:
			.localized("Signing")
		case .verifying:
			.localized("Verifying the signature")
		case .registering:
			.localized("Adding to the library")
		}
	}
}
