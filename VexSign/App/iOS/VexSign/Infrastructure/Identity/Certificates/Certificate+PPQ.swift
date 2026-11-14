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
