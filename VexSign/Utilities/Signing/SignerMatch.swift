//
//  SignerMatch.swift
//  VexSign
//
//  Does the certificate about to sign match the one the bundle already carries?
//
//  Re-signing a library app with a different certificate is legal and sometimes deliberate, but
//  it is not a no-op: the app already installed on the device was signed by the old identity, so
//  iOS refuses to update it in place and the app's keychain items — logins, tokens, app-group
//  data — do not survive the delete-and-reinstall that is the only way through.
//
//  This is the comparison, and the sentence that explains that consequence. It is deliberately
//  conservative: without certificates on both sides it answers `unknown`, because a warning
//  nobody can act on is worse than no warning.
//

import Foundation
import NimbleExtensions

// MARK: - Match

enum SignerMatch: Equatable, Sendable {
	/// The bundle carries a certificate that the selected certificate also carries.
	case same(SigningIdentity)
	/// The bundle carries a certificate the selected certificate does not.
	case different(bundle: SigningIdentity, selected: String)
	/// No basis for a comparison. Never rendered as a warning.
	case unknown(String)

	var isMismatch: Bool {
		if case .different = self { return true }
		return false
	}

	/// The bundle's own signing certificate, when it has one.
	var signer: SigningIdentity? {
		switch self {
		case .same(let signer): signer
		case .different(let signer, _): signer
		case .unknown: nil
		}
	}

	/// The explanation shown before re-signing. Only a real mismatch has one.
	var detail: String? {
		guard case .different(let signer, let selected) = self else { return nil }
		return String.localized(
			"This app was signed with “%@”. Signing it with %@ changes its identity: iOS will not update the copy already installed on your device in place, so it has to be deleted and installed again — and anything the app kept in the keychain goes with it.",
			arguments: signer.displayName, selected
		)
	}

	/// One line for the info sheet, where there is no warning to act on.
	var summary: String {
		switch self {
		case .same:
			.localized("Matches the certificate on this entry.")
		case .different(let signer, let selected):
			.localized("Signed with %@, not %@.", arguments: signer.displayName, selected)
		case .unknown(let reason):
			reason
		}
	}

	// MARK: Evaluate

	/// Compares the certificates a bundle carries with the ones a `CertificatePair` authorizes.
	///
	/// - Parameters:
	///   - bundle: certificates read from the stored bundle's signature.
	///   - selected: certificates the selected profile authorizes (its `DeveloperCertificates`).
	///   - selectedLabel: what to call the selected certificate in the warning.
	static func evaluate(
		bundle: [SigningIdentity],
		selected: [SigningIdentity],
		selectedLabel: String
	) -> SignerMatch {
		guard let signer = bundle.first else {
			return .unknown(.localized("This app's signature carries no certificate."))
		}

		guard !selected.isEmpty else {
			return .unknown(.localized("The selected certificate's own certificate could not be read."))
		}

		let fingerprints = Set(selected.map(\.fingerprint))
		if fingerprints.contains(signer.fingerprint) {
			return .same(signer)
		}

		// A chain can carry more than the signer; any relation is enough to call it the same
		// identity, because that is what iOS compares.
		if let related = bundle.first(where: { fingerprints.contains($0.fingerprint) }) {
			return .same(related)
		}

		return .different(bundle: signer, selected: selectedLabel)
	}
}
