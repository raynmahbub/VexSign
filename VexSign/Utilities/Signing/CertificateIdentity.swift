//
//  CertificateIdentity.swift
//  VexSign
//
//  Turning a `CertificatePair` into the certificates iOS will accept from it.
//
//  A `.p12` holds a private key and its certificate, but the profile is what decides: the
//  `DeveloperCertificates` array lists every certificate the profile authorizes, and iOS
//  compares the signer against that list on install. So the profile is the honest answer to
//  "which certificates is this identity?", it needs no password to read, and it is exactly
//  what a bundle signed "with this certificate" must carry.
//

import Foundation
import NimbleExtensions

@MainActor
enum CertificateIdentity {
	/// The certificates this pair's profile authorizes. Empty when the profile is missing or
	/// carries none — which the caller must treat as "unknown", never as "mismatch".
	static func identities(of certificate: CertificatePair) -> [SigningIdentity] {
		guard
			let profile = Storage.shared.getProvisionFileDecoded(for: certificate),
			let certificates = profile.DeveloperCertificates,
			!certificates.isEmpty
		else {
			return []
		}

		return certificates.compactMap { SigningIdentity($0) }
	}

	/// What to call the certificate in a sentence.
	static func label(for certificate: CertificatePair) -> String {
		guard let nickname = certificate.nickname, !nickname.isEmpty else {
			return .localized("the selected certificate")
		}
		return String.localized("“%@”", arguments: nickname)
	}

	/// Compares the identity a stored app was signed with against this certificate.
	static func match(for app: AppInfoPresentable, certificate: CertificatePair) -> SignerMatch {
		guard let directory = Storage.shared.getAppDirectory(for: app) else {
			return .unknown(.localized("The app bundle could not be read."))
		}

		return match(forBundleAt: directory, certificate: certificate)
	}

	static func match(forBundleAt directory: URL, certificate: CertificatePair) -> SignerMatch {
		match(state: BundleSignature.read(bundleAt: directory), certificate: certificate)
	}

	/// The same comparison when the bundle has already been read (the library caches it).
	static func match(state: BundleSignature.State, certificate: CertificatePair) -> SignerMatch {
		guard state.hasCertificate else {
			return .unknown(reason(for: state))
		}

		return SignerMatch.evaluate(
			bundle: state.identities,
			selected: identities(of: certificate),
			selectedLabel: label(for: certificate)
		)
	}

	/// Why there is nothing to compare, in a sentence.
	static func reason(for state: BundleSignature.State) -> String {
		switch state {
		case .noCodeSignature:
			.localized("The stored app is not signed, so there is no earlier identity to compare.")
		case .noCertificates:
			.localized("The stored app is ad-hoc signed, so its signature carries no certificate.")
		case .unreadable(let reason):
			reason
		case .certificates:
			.localized("The stored app's certificate could not be compared.")
		}
	}
}
