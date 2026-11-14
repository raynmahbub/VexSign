//
//  ProfileCompatibility.swift
//  VexSign
//
//  Answers one question before signing starts: can this certificate's provisioning profile
//  sign *this* app? (audit .)
//
//  Until now the answer was discovered two minutes later, at install time: an explicit App ID
//  that does not cover the bundle, an entitlement the profile never granted, an extension the
//  profile cannot cover, or a profile paired with the wrong certificate all surfaced as an
//  install failure with no explanation.
//
//  Everything here is pure apart from the two `CertificatePair` helpers at the bottom, which
//  read what is already on disk. No network access, and no state.
//

import CryptoKit
import Foundation
import NimbleExtensions
import Security

// MARK: - Engine

extension ProfileCompatibility {
	// MARK: Evaluate

	static func evaluate(
		profile: Certificate?,
		leafCertificateDER: Data? = nil,
		target: Target
	) -> Evaluation {
		guard let profile else {
			return Evaluation(
				verdict: .unknown,
				issues: [
					Issue(
						code: .profileMissing,
						severity: .warning,
						detail: .localized("This certificate has no readable provisioning profile, so it was not checked against the app.")
					)
				],
				suggestedBundleIdentifier: nil
			)
		}

		var issues: [Issue] = []
		let pattern = profile.Entitlements?["application-identifier"]?.value as? String

		// 1. Expiry. An expired profile fails at install, so it blocks here.
		if profile.ExpirationDate < Date() {
			issues.append(
				Issue(
					code: .profileExpired,
					severity: .blocking,
					detail: .localized(
						"The provisioning profile expired on %@.",
						arguments: profile.ExpirationDate.formatted(date: .abbreviated, time: .omitted)
					)
				)
			)
		}

		// 2. Does the profile cover the app identifier?
		let covered = pattern.map { SignatureVerifier.coverage(of: $0, includes: target.bundleIdentifier ?? "") } ?? false
		let malformation: ProfileApplicationIdentifierMatcher.Malformation? = pattern.flatMap {
			// A value with no prefix is compared literally by `coverage`, as it always was.
			guard $0.contains("."), case .failure(let reason) = ProfileApplicationIdentifierMatcher.parse($0) else { return nil }
			return reason
		}
		if let pattern, let malformation, let identifier = target.bundleIdentifier, !identifier.isEmpty, !covered {
			// The profile's own App ID cannot be read as one, so it authorizes nothing and
			// there is no identifier to suggest.
			issues.append(
				Issue(
					code: .appIdentifierMismatch,
					severity: .blocking,
					detail: .localized(
						"The profile's App ID (%@) is not a valid App ID (%@), so it cannot authorize %@.",
						arguments: pattern, malformation.rawValue, identifier
					)
				)
			)
		} else if let pattern, let identifier = target.bundleIdentifier, !identifier.isEmpty, !covered {
			let suggestion = SignatureVerifier.isWildcard(pattern)
				? nil
				: pattern.split(separator: ".", maxSplits: 1).last.map(String.init)

			issues.append(
				Issue(
					code: .appIdentifierMismatch,
					severity: .blocking,
					detail: suggestion.map {
						.localized(
							"The profile covers %@, so it cannot sign %@. Change the bundle identifier to %@ or pick a different certificate.",
							arguments: pattern, identifier, $0
						)
					} ?? .localized(
						"The profile covers %@, so it cannot sign %@.",
						arguments: pattern, identifier
					)
				)
			)
		}

		// 3. Retained extensions have to be covered too. Strict mode blocks because the signer
		// uses the outer asset for every nested bundle; compatibility mode instead warns because
		// the handler will remove only the known-uncovered bundles before signing.
		if let pattern {
			for nested in target.nestedBundleIdentifiers
			where !SignatureVerifier.coverage(of: pattern, includes: nested)
				&& !AdditionalProfiles.covers(nested, patterns: target.additionalProfilePatterns) {
				issues.append(
					Issue(
						code: .extensionNotCovered,
						severity: target.automaticallyRemoveUncoveredExtensions && target.removableExtensionIdentifiers.contains(nested) ? .warning : .blocking,
						detail: target.automaticallyRemoveUncoveredExtensions && target.removableExtensionIdentifiers.contains(nested)
							? .localized("%@ is not covered by this profile and will be removed in compatibility mode. The main app and covered extensions will still be signed.", arguments: nested)
							: .localized("%@ is not covered by this profile, so it cannot be signed correctly. Use a profile that includes it, or enable compatibility mode to remove it.", arguments: nested)
					)
				)
			}
		}

		// 4. Requested entitlements the profile does not grant. Keys VexSign rewrites for itself
		// (keychain groups, JIT, team identifiers) are skipped — other checks own those.
		let granted = profile.Entitlements?.mapValues { $0.value } ?? [:]
		for (key, value) in target.requestedEntitlements.sorted(by: { $0.key < $1.key }) {
			guard !SignatureVerifier.tolerantEntitlementKeys.contains(key) else { continue }
			guard let grantedValue = granted[key] else {
				issues.append(
					Issue(
						code: .entitlementNotGranted,
						severity: .blocking,
						detail: .localized("The profile does not grant %@, so the app will not launch with it.", arguments: key)
					)
				)
				continue
			}

			if let requested = value as? [Any] {
				let grantedElements = Set((grantedValue as? [Any] ?? []).map { _describe($0) })
				let missing = requested.compactMap { $0 as? String }.filter { !grantedElements.contains($0) }
				if !missing.isEmpty {
					issues.append(
						Issue(
							code: .entitlementNotGranted,
							severity: .blocking,
							detail: .localized(
								"The profile does not grant %@ for %@.",
								arguments: key, missing.joined(separator: ", ")
							)
						)
					)
				}
			} else if _describe(value) != _describe(grantedValue) {
				issues.append(
					Issue(
						code: .entitlementNotGranted,
						severity: .blocking,
						detail: .localized(
							"%@ is requested as %@ but the profile grants %@.",
							arguments: key, _describe(value), _describe(grantedValue)
						)
					)
				)
			}
		}

		// 5. Team identity. A profile from one team cannot sign an app built against another.
		if
			let expectedTeam = target.teamIdentifier,
			let profileTeam = profile.TeamIdentifier.first,
			!Self.prefixBelongsToProfile(
				expectedTeam,
				teamIdentifiers: profile.TeamIdentifier,
				applicationIdentifierPrefixes: profile.ApplicationIdentifierPrefix ?? []
			) {
			issues.append(
				Issue(
					code: .teamMismatch,
					severity: .blocking,
					detail: .localized(
						"The profile belongs to team %@ but this app is set up for team %@.",
						arguments: profileTeam, expectedTeam
					)
				)
			)
		}

		// 6. The certificate in the p12 must be one the profile names.
		if let leafCertificateDER, let candidates = profile.DeveloperCertificates, !candidates.isEmpty {
			let fingerprint = _fingerprint(leafCertificateDER)
			let known = candidates.map { _fingerprint($0) }
			if !known.contains(fingerprint) {
				issues.append(
					Issue(
						code: .certificateNotInProfile,
						severity: .blocking,
						detail: .localized("This profile was issued for a different certificate, so installs signed with this pair will be rejected.")
					)
				)
			}
		}

		// 7. Device provisioning, when the device is known.
		if
			let deviceUDID = target.deviceUDID,
			profile.ProvisionsAllDevices != true,
			let devices = profile.ProvisionedDevices,
			!devices.isEmpty,
			!devices.contains(deviceUDID) {
			issues.append(
				Issue(
					code: .deviceNotProvisioned,
					severity: .blocking,
					detail: .localized("This device is not in the profile's device list, so the app will not install.")
				)
			)
		}

		// 8. Profile type. A profile with no device list that is neither In-House nor a
		// development profile is an App Store distribution profile, and iOS installs apps
		// signed with one only through the App Store or TestFlight. Advisory, because the
		// type is inferred from which keys are present rather than stated by the profile.
		if profile.profileType == .distribution {
			issues.append(
				Issue(
					code: .deviceNotProvisioned,
					severity: .warning,
					detail: .localized("This profile lists no devices and is not an In-House profile, so it appears to be an App Store distribution profile. An app signed with it will not install directly on a device.")
				)
			)
		}

		let verdict: Verdict
		if issues.contains(where: \.isBlocking) {
			verdict = .unusable
		} else if pattern == nil || (target.bundleIdentifier ?? "").isEmpty {
			verdict = .unknown
		} else if let pattern, SignatureVerifier.isWildcard(pattern) {
			verdict = .wildcard
		} else {
			verdict = .covers
		}

		return Evaluation(
			verdict: verdict,
			issues: issues,
			suggestedBundleIdentifier: verdict == .unusable && malformation == nil
				? pattern.flatMap { SignatureVerifier.isWildcard($0) ? nil : $0.split(separator: ".", maxSplits: 1).last.map(String.init) }
				: nil
		)
	}

	/// Convenience for the certificate picker, which has no certificate bytes to compare.
	static func verdict(profile: Certificate?, target: Target) -> Verdict {
		evaluate(profile: profile, target: target).verdict
	}

	// MARK: Readings

	/// Entitlements from a picked plist, or empty when none is set or it cannot be read.
	static func entitlements(at url: URL?) -> [String: Any] {
		guard let url, let dictionary = NSDictionary(contentsOf: url) as? [String: Any] else { return [:] }
		return dictionary
	}

	/// Whether the prefix on an app's `application-identifier` is one this profile uses.
	///
	/// That prefix is an App ID prefix. For current accounts it equals the Team ID, but
	/// App IDs created under older accounts keep a prefix of their own, so a profile is
	/// only for another team when the prefix matches neither its Team ID nor any App ID
	/// prefix it lists. Comparing with the Team ID alone reported those profiles as a
	/// team mismatch.
	static func prefixBelongsToProfile(
		_ prefix: String,
		teamIdentifiers: [String],
		applicationIdentifierPrefixes: [String]
	) -> Bool {
		teamIdentifiers.contains(prefix) || applicationIdentifierPrefixes.contains(prefix)
	}

	/// The prefix carried by an `application-identifier`, when one is present. Usually the
	/// Team ID; see `prefixBelongsToProfile`.
	static func teamIdentifier(in entitlements: [String: Any]) -> String? {
		guard
			let identifier = entitlements["application-identifier"] as? String,
			let team = identifier.split(separator: ".").first.map(String.init),
			!team.isEmpty
		else {
			return nil
		}
		return team
	}

	// MARK: Helpers

	private static func _fingerprint(_ der: Data) -> String {
		SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
	}

	private static func _describe(_ value: Any) -> String {
		switch value {
		case let bool as Bool:
			return bool ? "true" : "false"
		case let string as String:
			return string
		case let number as NSNumber:
			return number.stringValue
		default:
			return String(describing: value)
		}
	}
}

// MARK: - CertificatePair

extension CertificatePair {
	/// The DER of the certificate inside the stored p12, read without importing it into the
	/// keychain and without a user prompt. Nil when the password is unavailable (locked
	/// keychain) or the p12 cannot be parsed — in both cases the compatibility check simply
	/// skips the "certificate is in this profile" question instead of guessing.
	var appliedCertificateDER: Data? {
		guard
			let url = Storage.shared.getFile(.certificate, from: self),
			let password = signingPassword,
			let data = try? Data(contentsOf: url),
			!data.isEmpty
		else {
			return nil
		}

		var items: CFArray?
		let options = [kSecImportExportPassphrase as String: password] as CFDictionary
		guard
			SecPKCS12Import(data as CFData, options, &items) == errSecSuccess,
			let entries = items as? [[String: Any]],
			let identity = entries.compactMap({ $0[kSecImportItemIdentity as String] }).first
		else {
			return nil
		}

		// `SecPKCS12Import` hands the identity back as a `CFTypeRef` inside the
		// dictionary. Swift rejects `as?` on a CF type ("will always succeed") and
		// refuses the bare `as` from `Any`, so the forced cast is the spelling left;
		// it cannot fail here for the same reason the conditional one could not.
		// swiftlint:disable:next force_cast
		let secIdentity = identity as! SecIdentity

		var certificate: SecCertificate?
		guard
			SecIdentityCopyCertificate(secIdentity, &certificate) == errSecSuccess,
			let certificate
		else {
			return nil
		}

		return SecCertificateCopyData(certificate) as Data
	}
}

extension ProfileCompatibility.Target {
		/// The app as the signing options will leave it.
		init(
			app: AppInfoPresentable,
			options: Options,
			nestedBundleIdentifiers: [String] = [],
			removableExtensionIdentifiers: Set<String>? = nil,
			additionalProfilePatterns: [String] = []
		) {
			let requested = ProfileCompatibility.entitlements(at: options.appEntitlementsFile)
			let effectiveOverride = options.effectiveAppIdentifier

			// The app identifier below is already the one the options will produce. The nested
			// identifiers come off disk, so they still carry the *old* base; the signer rewrites
			// them the same way. Judging them unrewritten reported extensions as uncovered that
			// the profile covers after the rename (#137).
			let rewrite: (String) -> String = {
				NestedBundleAudit.rewrittenIdentifier($0, from: app.identifier, to: effectiveOverride)
			}

			self.init(
				bundleIdentifier: effectiveOverride ?? app.identifier,
				nestedBundleIdentifiers: nestedBundleIdentifiers.map(rewrite),
				automaticallyRemoveUncoveredExtensions: options.autoRemoveUnsupportedExtensions,
				removableExtensionIdentifiers: removableExtensionIdentifiers.map { Set($0.map(rewrite)) },
				requestedEntitlements: requested,
				teamIdentifier: ProfileCompatibility.teamIdentifier(in: requested)
			)
			self.additionalProfilePatterns = additionalProfilePatterns
		}
}
