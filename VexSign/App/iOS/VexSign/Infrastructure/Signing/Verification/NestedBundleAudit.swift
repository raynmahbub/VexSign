//
//  NestedBundleAudit.swift
//  VexSign
//
//  Identifier-coverage display compatibility for existing certificate screens.
//  Device admission uses SigningResolutionSession/ProfileCompatibilityValidator
//  for every component's own identity, authenticated profile and entitlements.
//  This view reads the same bounded recursive manifest as that path; profile
//  pattern coverage alone is not proof that a component can be signed.
//

import Foundation
import NimbleExtensions

// MARK: - Bundle

/// One nested bundle that iOS expects to carry its own provisioning profile.
struct NestedBundle: Equatable {
	enum Kind: String, Equatable {
		case appExtension
		case watchApp
        case embeddedApp
	}

	/// Path relative to the `.app`, e.g. `PlugIns/Widget.appex`.
	let path: String
	/// `CFBundleIdentifier`, when the bundle has a readable `Info.plist`.
	let identifier: String?
	let kind: Kind

	/// `Widget.appex` — what a log line should call this thing.
	var displayName: String {
		(path as NSString).lastPathComponent
	}
}

// MARK: - Audit

enum NestedBundleAudit {
	/// What the selected profile can do for one nested bundle.
	enum Coverage: Equatable {
		/// The profile's App ID covers this bundle.
		case covered(pattern: String)
		/// The profile exists and does not cover it.
		case notCovered(pattern: String)
		/// Nothing to compare: no profile selected, or the bundle has no identifier.
		/// This is reported as unknown rather than as a proven mismatch.
		case unknown

		var isNotCovered: Bool {
			if case .notCovered = self { return true }
			return false
		}
	}

	struct Entry: Equatable {
		let bundle: NestedBundle
		let coverage: Coverage
		/// `application-identifier` of the profile the bundle currently ships. A bundle that
		/// arrives carrying another account's profile is the usual reason an install fails.
		let shippedProfileIdentifier: String?
	}

	struct Report: Equatable {
		let entries: [Entry]
		/// The selected profile's `application-identifier`, wildcard included, when it has one.
		let profilePattern: String?

		var isEmpty: Bool { entries.isEmpty }
		var uncovered: [Entry] { entries.filter { $0.coverage.isNotCovered } }
		var unknown: [Entry] { entries.filter { $0.coverage == .unknown } }
		/// Clean means every scanned bundle is actually covered, not merely unverified.
		var isClean: Bool { uncovered.isEmpty && unknown.isEmpty }

        struct IncompatibleProfile: LocalizedError {
            let details: String
            var errorDescription: String? {
					.localized("The selected profile cannot sign all retained extensions. Choose a profile that includes them, enable automatic compatibility mode, or enable Remove App Extensions. %@", arguments: details)
            }
        }

        /// Stops the run when a retained nested bundle is known not to be covered.
        ///
        /// The engine signs every nested bundle with the selected profile, so an extension
        /// that profile does not include is signed with an App ID that is not its own and
        /// iOS rejects the install. That is not a risk the user can accept on the preflight
        /// sheet: the ways through are a profile that includes the bundle, or removing the
        /// extension, which compatibility mode and Remove App Extensions both do before
        /// this check runs. `overridingBlockingIssues` is kept for source compatibility and
        /// no longer changes the answer.
        func requireCompatibleProfile(overridingBlockingIssues: Bool = false) throws {
            guard isClean else { throw IncompatibleProfile(details: warnings.joined(separator: " ")) }
        }

		/// Explain known mismatches and unknown coverage without conflating them.
		var warnings: [String] {
			entries.compactMap { entry in
				let name = entry.bundle.displayName
				let identifier = entry.bundle.identifier ?? .localized("unknown identifier")
				switch entry.coverage {
				case .covered:
					return nil
				case .unknown:
					return .localized("Coverage could not be determined for %@ (%@).", arguments: name, identifier)
				case let .notCovered(pattern):
					if let shipped = entry.shippedProfileIdentifier, shipped != pattern {
						return .localized(
							"%@ (%@) ships a profile for %@; the selected profile covers %@, so the extension cannot be signed correctly.",
							arguments: name, identifier, shipped, pattern
						)
					}
					return .localized(
						"%@ (%@) is not covered by %@, so the extension cannot be signed correctly.",
						arguments: name, identifier, pattern
					)
				}
			}
		}

		/// The one-line verdict for the signing log, or nil when there is nothing to say.
		var summary: String? {
			guard !isEmpty else { return nil }
			if isClean {
				return .localized("%lld nested bundle(s) covered by the profile.", arguments: entries.count)
			}
			if !unknown.isEmpty {
				return .localized(
					"%lld of %lld nested bundles are not covered; %lld have unknown coverage.",
					arguments: uncovered.count, entries.count, unknown.count
				)
			}
			return .localized(
				"%lld of %lld nested bundles are not covered by this profile.",
				arguments: uncovered.count, entries.count
			)
		}
	}

	// MARK: Scanning

	/// Every nested bundle that carries a profile requirement, in a stable order.
    static func bundles(in appBundle: URL) -> [NestedBundle] {
        SigningPlan.make(appBundle: appBundle).profileBoundComponents.map { component in
            NestedBundle(path: component.path, identifier: component.identifier,
                kind: (component.path as NSString).pathExtension.lowercased() == "appex" ? .appExtension : (component.kind == .watchApp ? .watchApp : .embeddedApp))
        }.sorted { $0.path < $1.path }
    }

	/// Identifiers the profile has to cover for the app to work after signing.
	///
	/// App extensions stripped by `removeAppExtensions` never reach the signer. Watch apps are
	/// not app extensions, so they remain in the target and must still be covered.
	static func requiredIdentifiers(in appBundle: URL, removeAppExtensions: Bool) -> [String] {
		bundles(in: appBundle)
			.filter { !removeAppExtensions || $0.kind != .appExtension }
			.compactMap(\.identifier)
			.sorted()
	}

	/// Extensions compatibility mode is allowed to remove. Watch apps are intentionally excluded.
	static func removableExtensionIdentifiers(in appBundle: URL, removeAppExtensions: Bool) -> Set<String> {
		guard !removeAppExtensions else { return [] }
		return Set(bundles(in: appBundle).compactMap { bundle in
			bundle.kind == .appExtension ? bundle.identifier : nil
		})
	}

	// MARK: Identifier rewrite

	/// The identifier a nested bundle will carry after the app's bundle id is changed.
	///
	/// Both `SigningHandler._modifyPluginIdentifiers` and the pinned engine
	/// (`ZBundle::ModifyPluginsBundleId`, `VexSign/Packages/Vendor/Zsign/src/bundle.cpp:390`) rewrite every
	/// nested `.app`/`.appex` by replacing the old app identifier with the new one. Coverage
	/// therefore has to be judged on the *result*: an extension that looks uncovered before
	/// the rename is covered afterwards whenever the profile covers the new identifier.
	/// Comparing the pre-rename value is what made a wildcard profile appear to reject
	/// extensions it actually covers (#137).
	static func rewrittenIdentifier(_ identifier: String, from oldBase: String?, to newBase: String?) -> String {
		guard let oldBase, !oldBase.isEmpty, let newBase, !newBase.isEmpty, oldBase != newBase else {
			return identifier
		}
		if identifier == oldBase { return newBase }
        guard identifier.hasPrefix(oldBase + ".") else { return identifier }
        return newBase + String(identifier.dropFirst(oldBase.count))
	}

	// MARK: Reporting

	/// Audits an app against the selected profile, reading each nested bundle's own profile.
	static func report(appBundle: URL, profilePattern: String?, additionalPatterns: [String] = []) -> Report {
		report(
			appBundle: appBundle,
			profilePattern: profilePattern,
			additionalPatterns: additionalPatterns,
			shippedProfile: shippedProfileIdentifier(at:)
		)
	}

	/// Removes only app extensions whose identifiers are positively known not to be covered.
	/// Unknown coverage, compatible extensions, and watch apps are kept. The returned entries
	/// let the caller report exactly what was skipped.
	@discardableResult
	static func removeUncoveredBundles(
		in appBundle: URL,
		profilePattern: String,
		additionalPatterns: [String] = [],
		fileManager: FileManager = .default
	) throws -> [Entry] {
		let uncovered = report(appBundle: appBundle, profilePattern: profilePattern, additionalPatterns: additionalPatterns).uncovered
			.filter { $0.bundle.kind == .appExtension }
        for entry in uncovered where try !OptionalExtensionPolicy.canRemove(entry.bundle.path, in: appBundle) {
            throw SigningFileHandlerError.identityRejected("This extension cannot be safely removed: " + entry.bundle.path)
        }
		for entry in uncovered {
			try fileManager.removeItem(at: appBundle.appendingPathComponent(entry.bundle.path))
		}
		return uncovered
	}

	/// The injectable form, so the comparison can be tested without real profiles on disk.
	static func report(
		appBundle: URL,
		profilePattern: String?,
		additionalPatterns: [String] = [],
		shippedProfile: (URL) -> String?
	) -> Report {
		let trimmed = profilePattern?.trimmingCharacters(in: .whitespacesAndNewlines)
		let usablePattern = (trimmed?.isEmpty == false) ? trimmed : nil

		let entries = bundles(in: appBundle).map { bundle -> Entry in
			let coverage: Coverage
			if let usablePattern, let identifier = bundle.identifier {
				// A bundle the main profile misses is still covered when one of the
				// certificate's additional profiles was issued for it; the engine signs
				// that bundle with that profile.
				if SignatureVerifier.coverage(of: usablePattern, includes: identifier) {
					coverage = .covered(pattern: usablePattern)
				} else if let own = additionalPatterns.first(where: { SignatureVerifier.coverage(of: $0, includes: identifier) }) {
					coverage = .covered(pattern: own)
				} else {
					coverage = .notCovered(pattern: usablePattern)
				}
			} else {
				coverage = .unknown
			}

			return Entry(
				bundle: bundle,
				coverage: coverage,
				shippedProfileIdentifier: shippedProfile(appBundle.appendingPathComponent(bundle.path))
			)
		}

		return Report(entries: entries, profilePattern: usablePattern)
	}

	/// `application-identifier` of the profile a nested bundle already carries, if it has one.
	static func shippedProfileIdentifier(at bundle: URL) -> String? {
		let profile = bundle.appendingPathComponent("embedded.mobileprovision")
		guard FileManager.default.fileExists(atPath: profile.path) else { return nil }
		return CertificateReader(profile).decoded?.Entitlements?["application-identifier"]?.value as? String
	}

}
