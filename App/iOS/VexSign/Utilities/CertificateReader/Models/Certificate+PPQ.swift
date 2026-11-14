//
//  Certificate+PPQ.swift
//  VexSign
//
//  PPQ / PPQLess classification for a certificate + provisioning profile pair.
//
//  Apple can revoke a sideloaded app the moment it queries the provisioning
//  profile ("PPQ"). Whether that happens is decided by the profile, not by
//  VexSign: development profiles are queryable, distribution-style profiles
//  (Ad Hoc / In-House / App Store) are not. This file turns the decoded
//  `.mobileprovision` into that answer so the UI can badge it and the signing
//  options can gate JIT, which needs `get-task-allow` — a development-profile
//  only entitlement.
//
//  Nothing here modifies the profile: signing still passes the untouched
//  `.mobileprovision` to Zsign, so a PPQLess pair stays PPQLess.
//

import Foundation
import SwiftUI
import NimbleExtensions

// MARK: - Profile type

/// Flavour of the embedded provisioning profile, derived from its plist.
enum ProvisionProfileType: String, Codable, Sendable, CaseIterable {
	case development
	case enterprise
	case adHoc
	case distribution
	case unknown

	var title: String {
		switch self {
		case .development: .localized("Development")
		case .enterprise: .localized("Enterprise (In-House)")
		case .adHoc: .localized("Ad Hoc")
		case .distribution: .localized("Distribution")
		case .unknown: .localized("Unknown")
		}
	}

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

// MARK: - CertificatePair (library entry)

extension CertificatePair {
	/// Decoded profile on disk, or nil when the `.mobileprovision` went missing.
	var decodedProfile: Certificate? {
		Storage.shared.getProvisionFileDecoded(for: self)
	}

	var profileType: ProvisionProfileType {
		decodedProfile?.profileType ?? .unknown
	}

	/// PPQLess when the profile says so. The flag captured at import wins when the
	/// profile file is gone, so a certificate never silently loses its badge.
	var isPPQLess: Bool {
		if ppQCheck { return false }
		guard let profile = decodedProfile else { return false }
		return profile.isPPQLess
	}

	var isPPQ: Bool { !isPPQLess }

	/// JIT entitlements are only honoured on PPQ certificates.
	var supportsJIT: Bool { !isPPQLess }

	/// Reason shown next to a disabled JIT toggle; nil when JIT is allowed.
	var jitBlockReason: String? {
		guard isPPQLess else { return nil }
		return String.localized("JIT requires a PPQ certificate. This one uses a PPQLess distribution profile.")
	}

	/// Green for PPQLess, orange for PPQ — see `CertificatesCellView`.
	var ppqBadge: (title: String, icon: String, color: Color) {
		isPPQLess
			? (.localized("PPQLess"), "shield.lefthalf.filled", .green)
			: (.localized("PPQ"), "shield.slash", .orange)
	}
}
