import Foundation

enum ProvisionProfileType: String, Codable, Sendable, CaseIterable {
	case development
	case enterprise
	case adHoc
	case distribution
	case unknown


	/// Development profiles are the only ones Apple revokes through PPQ.
	var isPPQTrackedType: Bool { self == .development }
}

// MARK: - Certificate (decoded .mobileprovision)

extension Certificate {
	/// Entitlements that mark a profile as PPQ-tracked even when it looks like a
	/// distribution profile (private keys Apple hands to tracked signers).
	static let ppqSpecialAccessEntitlements: [String] = [
		"com.apple.developer.ios-special-access",
		"com.apple.private.provisioning-profile-tracking",
	]

	var entitlementKeys: Set<String> {
		guard let entitlements = Entitlements else { return [] }
		return Set(entitlements.keys)
	}

	var hasSpecialAccessEntitlement: Bool {
		!entitlementKeys.isDisjoint(with: Self.ppqSpecialAccessEntitlements)
	}

	/// Profile flavour. `get-task-allow` separates development from Ad Hoc, since
	/// both carry a device list; `ProvisionsAllDevices` marks In-House.
	var profileType: ProvisionProfileType {
		guard let entitlements = Entitlements else { return .unknown }
		if ProvisionsAllDevices == true { return .enterprise }
		if entitlements["get-task-allow"]?.value as? Bool == true { return .development }
		if ProvisionedDevices?.isEmpty == false { return .adHoc }
		return .distribution
	}

	/// The raw `PPQCheck` key some signing services stamp into the profile.
	var declaresPPQCheck: Bool { PPQCheck == true }

	/// True when Apple can revoke through the provisioning-profile query path.
	var isPPQTracked: Bool { !isPPQLess }

	/// A profile is PPQLess when it is a distribution-style profile that neither
	/// declares `PPQCheck` nor carries a special-access entitlement.
	var isPPQLess: Bool {
		let type = profileType
		guard type != .unknown, !type.isPPQTrackedType else { return false }
		guard !declaresPPQCheck, !hasSpecialAccessEntitlement else { return false }
		return true
	}

	/// JIT needs a debugger-attachable binary (`get-task-allow`), which only
	/// development — i.e. PPQ-tracked — profiles provide.
	var supportsJIT: Bool { !isPPQLess }
}
