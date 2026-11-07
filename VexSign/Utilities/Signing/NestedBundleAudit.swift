//
//  NestedBundleAudit.swift
//  VexSign
//
//  What the selected profile can actually do for the extensions inside an app.
//
//  The bundled engine signs every nested bundle with the *outer* asset — one `ZSignAsset` for the
//  whole tree (`Vendor/Zsign/src/bundle.cpp:515-544` in the pin) — so an extension whose identifier the
//  profile does not cover cannot be signed correctly, and the install either fails or produces a
//  widget that never launches. Until the engine can take one asset per nested bundle, the honest
//  thing to do is say which extensions are in that state before the long sign starts, instead of
//  discovering it afterwards.
//
//  Frameworks are deliberately not audited: iOS does not require a provisioning profile for them,
//  so listing every `com.apple.SwiftUI`-style identifier as "not covered" would be pure noise.
//
//  Everything here is pure apart from reading `Info.plist` and an existing
//  `embedded.mobileprovision` off disk.
//

import Foundation
import NimbleExtensions

// MARK: - Bundle

/// One nested bundle that iOS expects to carry its own provisioning profile.
struct NestedBundle: Equatable {
	enum Kind: String, Equatable {
		case appExtension
		case watchApp
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
		/// Nothing to compare: no profile selected, or the bundle has no identifier. Unknown is
		/// not a problem — it is the absence of evidence, and it is never reported as one.
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
		/// True when nothing is known to be wrong. An `unknown` entry is not a failure.
		var isClean: Bool { uncovered.isEmpty }

        struct IncompatibleProfile: LocalizedError {
            let details: String
            var errorDescription: String? {
					.localized("The selected profile cannot sign all retained extensions. Choose a compatible profile, enable automatic compatibility mode, explicitly enable Remove App Extensions, or sign anyway. %@", arguments: details)
            }
        }

        func requireCompatibleProfile() throws {
            guard isClean else { throw IncompatibleProfile(details: warnings.joined(separator: " ")) }
        }

		/// One line per bundle that cannot be signed correctly, in scan order.
		var warnings: [String] {
			uncovered.compactMap { entry in
				guard case let .notCovered(pattern) = entry.coverage else { return nil }

				let name = entry.bundle.displayName
				let identifier = entry.bundle.identifier ?? .localized("unknown identifier")

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

		/// The one-line verdict for the signing log, or nil when there is nothing to say.
		var summary: String? {
			guard !isEmpty else { return nil }
			if isClean {
				return .localized("%lld nested bundle(s) covered by the profile.", arguments: entries.count)
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
		[
			(folder: "PlugIns", pathExtension: "appex", kind: NestedBundle.Kind.appExtension),
			(folder: "Extensions", pathExtension: "appex", kind: .appExtension),
			(folder: "Watch", pathExtension: "app", kind: .watchApp)
		].flatMap { _members(in: appBundle, folder: $0.folder, pathExtension: $0.pathExtension, kind: $0.kind) }
	}

	/// Identifiers the profile has to cover for the app to work after signing.
	///
	/// Extensions and watch apps that the options strip before signing (`removeAppExtensions`)
	/// never reach the engine, so they are not required to be covered — the preflight used to warn
	/// about them anyway, on bundles that no longer existed by the time the app was signed.
	static func requiredIdentifiers(in appBundle: URL, removeAppExtensions: Bool) -> [String] {
		guard !removeAppExtensions else { return [] }
		return bundles(in: appBundle).compactMap(\.identifier).sorted()
	}

	// MARK: Reporting

	/// Audits an app against the selected profile, reading each nested bundle's own profile.
	static func report(appBundle: URL, profilePattern: String?) -> Report {
		report(appBundle: appBundle, profilePattern: profilePattern, shippedProfile: shippedProfileIdentifier(at:))
	}

	/// The injectable form, so the comparison can be tested without real profiles on disk.
	static func report(
		appBundle: URL,
		profilePattern: String?,
		shippedProfile: (URL) -> String?
	) -> Report {
		let trimmed = profilePattern?.trimmingCharacters(in: .whitespacesAndNewlines)
		let usablePattern = (trimmed?.isEmpty == false) ? trimmed : nil

		let entries = bundles(in: appBundle).map { bundle -> Entry in
			let coverage: Coverage
			if let usablePattern, let identifier = bundle.identifier {
				coverage = SignatureVerifier.coverage(of: usablePattern, includes: identifier)
					? .covered(pattern: usablePattern)
					: .notCovered(pattern: usablePattern)
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

	// MARK: Helpers

	private static func _members(
		in appBundle: URL,
		folder: String,
		pathExtension: String,
		kind: NestedBundle.Kind
	) -> [NestedBundle] {
		let directory = appBundle.appendingPathComponent(folder)
		guard
			let contents = try? FileManager.default.contentsOfDirectory(
				at: directory,
				includingPropertiesForKeys: [.isDirectoryKey],
				options: [.skipsHiddenFiles]
			)
		else { return [] }

		return contents
			.filter { $0.pathExtension.lowercased() == pathExtension && $0.hasDirectoryPath }
			.map {
				NestedBundle(
					path: "\(folder)/\($0.lastPathComponent)",
					identifier: _identifier(of: $0),
					kind: kind
				)
			}
	}

	/// Reads `CFBundleIdentifier` straight from the bundle's plist. `Bundle(url:)` would work too,
	/// but it caches per path and returns nil for bundles whose plist lacks a package type, which
	/// some App Store payloads do.
	private static func _identifier(of bundle: URL) -> String? {
		guard let data = try? Data(contentsOf: bundle.appendingPathComponent("Info.plist")) else { return nil }
		guard let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else { return nil }
		guard
			let plist = object as? [String: Any],
			let identifier = plist["CFBundleIdentifier"] as? String,
			!identifier.isEmpty
		else { return nil }
		return identifier
	}
}
