//
//  SigningProfileStore.swift
//  VexSign
//
//  "Sign it again exactly like that": a persisted snapshot of the full signing
//  options plus the chosen certificate, keyed by bundle identifier. Update All
//  and "Re-sign with last settings" both read from here, so an app is updated
//  with the identity it was first signed with instead of re-picking everything.
//

import Foundation
import OSLog

// MARK: - Model
struct SigningProfile: Codable, Equatable {
	/// Bundle identifier the profile was captured for (the app's own id, not the PPQ-mangled one).
	let bundleID: String
	/// Full options snapshot — tweaks, entitlements, Info.plist overrides, display name, keychain isolation.
	let options: Options
	/// The `CertificatePair.uuid` used at capture. `nil` means "default / whatever is selected now".
	let certificateUUID: String?
	/// When it was last used, for display in the picker.
	let savedAt: Date
	/// Names, never paths, of the one-time tweak files the captured sign injected.
	///
	/// Those files are staged for one sign and are not kept, so the saved options must not point
	/// at them: replaying a dead staging URL is what made "Re-sign with last settings" and Update
	/// All stop in the Customize step. The names are kept so a replay can say what it left out.
	/// Optional, so a profile saved before this field existed still decodes.
	var oneShotFileNames: [String]? = nil
}

extension SigningProfile {
	/// The profile as a later sign may reuse it: no one-shot file URLs, and their names kept.
	///
	/// Applied on every read as well as on capture, because profiles written by earlier versions
	/// are already on disk with URLs into a temporary directory that no longer holds the files.
	func replayable() -> SigningProfile {
		guard !options.injectionFiles.isEmpty else { return self }

		var reusable = options
		reusable.injectionFiles = []
		return SigningProfile(
			bundleID: bundleID,
			options: reusable,
			certificateUUID: certificateUUID,
			savedAt: savedAt,
			oneShotFileNames: OneShotTweakFiles.merged(
				oneShotFileNames,
				OneShotTweakFiles.names(options.injectionFiles)
			)
		)
	}
}

// MARK: - Identity resolution

/// What the identity a profile captured resolves to today.
///
/// A profile stores `certificateUUID`. Certificates get deleted, re-imported and replaced, so
/// that reference can outlive the row it named. The store used to answer such a profile with the
/// *currently selected* certificate and say nothing, which meant an automatic re-sign (Update All,
/// Auto Sign) could quietly switch identities — the one thing the app warns the user about when
/// they do it by hand.
enum SigningIdentityResolution: Equatable, Sendable {
    /// The profile captured no identity; using the current selection is the documented behaviour.
    case currentSelection
    /// The captured identity is still installed.
    case captured(uuid: String)
    /// The captured identity is no longer installed. Callers may fall back, but must not claim
    /// the result is the same identity.
    case orphaned(uuid: String)

    var capturedUUID: String? {
        switch self {
        case .currentSelection: nil
        case .captured(let uuid), .orphaned(let uuid): uuid
        }
    }

    var isOrphaned: Bool {
        if case .orphaned = self { return true }
        return false
    }
}

// MARK: - Store
/// Backed by UserDefaults (JSON) — small snapshots, keyed by bundle id. `Codable` via `Options`.
final class SigningProfileStore {
	static let shared = SigningProfileStore()

	private static let defaultsKey = "VexSign.signingProfiles"

	private init() {}

	// MARK: Read / write

	private var all: [String: SigningProfile] {
		get {
			guard
				let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
				let decoded = try? JSONDecoder().decode([String: SigningProfile].self, from: data)
			else {
				return [:]
			}
			return decoded
		}
		set {
			if newValue.isEmpty {
				UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
			} else if let data = try? JSONEncoder().encode(newValue) {
				UserDefaults.standard.set(data, forKey: Self.defaultsKey)
			}
		}
	}

	func profile(forBundleID bundleID: String?) -> SigningProfile? {
		guard let bundleID, !bundleID.isEmpty else { return nil }
		return all[bundleID]?.replayable()
	}

	func save(_ profile: SigningProfile) {
		guard !profile.bundleID.isEmpty else { return }
		var store = all
		store[profile.bundleID] = profile.replayable()
		all = store
	}

	func remove(bundleID: String?) {
		guard let bundleID, !bundleID.isEmpty else { return }
		var store = all
		store.removeValue(forKey: bundleID)
		all = store
	}

	func clear() {
		all = [:]
	}

	// MARK: Convenience

	/// Records the options + certificate used to sign `app`, so the next sign (or Update All)
	/// can reproduce it without touching the signing screen.
	func capture(options: Options, certificate: CertificatePair?, for app: AppInfoPresentable) {
		guard let bundleID = app.identifier, !bundleID.isEmpty else { return }

		// Per-app identity fields must not be persisted in the shared defaults or every later
		// "resolved(for:)" would adopt this app's mangled identifier.
		var snapshot = options
		snapshot.appName = nil
		snapshot.appVersion = nil
		snapshot.appIdentifier = nil
		snapshot.appEntitlementsFile = nil

		// One-shot tweak files are not persisted either: `save` keeps their names and drops the
		// staging URLs (see `SigningProfile.replayable()`).
		save(SigningProfile(
			bundleID: bundleID,
			options: snapshot,
			certificateUUID: certificate?.uuid,
			savedAt: Date()
		))
	}

	func capture(options: Options, certificateUUID: String?, for app: AppInfoPresentable) {
		guard let bundleID = app.identifier, !bundleID.isEmpty else { return }

		var snapshot = options
		snapshot.appName = nil
		snapshot.appVersion = nil
		snapshot.appIdentifier = nil
		snapshot.appEntitlementsFile = nil

		save(SigningProfile(
			bundleID: bundleID,
			options: snapshot,
			certificateUUID: certificateUUID,
			savedAt: Date()
		))
	}

	/// Resolves the certificate a stored profile points at, falling back to the app-wide selection.
	/// Resolves the identity a profile captured against the certificates installed right now.
	///
	/// Pure and injectable: the store's own callers pass the real inventory, and tests pass a
	/// set, so the orphan rule is verifiable without a store, a Keychain or a certificate file.
	static func resolveIdentity(captured: String?, available: Set<String>) -> SigningIdentityResolution {
		guard let captured else { return .currentSelection }
		let key = captured.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		guard !key.isEmpty else { return .currentSelection }
		return available.contains(key) ? .captured(uuid: key) : .orphaned(uuid: key)
	}

	/// The certificate to sign with, and the truth about whether it is the one the profile wanted.
	///
	/// The fallback is kept — refusing to sign an app because an older profile points at a deleted
	/// identity would strand the app — but it is no longer silent: an orphaned reference is logged
	/// here and reported to automatic runs as a notice.
	func certificate(for profile: SigningProfile?) -> CertificatePair? {
		let certificates = Storage.shared.getAllCertificates()
		let available = Set(certificates.compactMap { $0.uuid?.lowercased() })
		let resolution = Self.resolveIdentity(captured: profile?.certificateUUID, available: available)

		switch resolution {
		case .captured(let uuid):
			if let match = certificates.first(where: { $0.uuid?.lowercased() == uuid }) {
				return match
			}
			// The inventory changed between the lookup and the match. Report it the same way as a
			// reference that was already known to be gone instead of guessing.
			return _currentSelection(replacingOrphaned: uuid)
		case .orphaned(let uuid):
			return _currentSelection(replacingOrphaned: uuid)
		case .currentSelection:
			return _currentSelection(replacingOrphaned: nil)
		}
	}

	/// The documented fallback, made audible.
	///
	/// Refusing to sign because an older profile points at a deleted identity would strand the app;
	/// signing silently with another key would hide an identity change that the app warns about
	/// when the user makes it by hand. So the run continues and says what it substituted.
	private func _currentSelection(replacingOrphaned reference: String?) -> CertificatePair? {
		if let reference {
			Logger.misc.warning(
				"Signing profile identity is no longer installed; signing with the current selection instead. Reference: \(reference.suffix(8), privacy: .public)"
			)
		}
		return Storage.shared.getCertificate(for: UserDefaults.standard.integer(forKey: "vexsign.selectedCert"))
	}

	/// Bundle identifiers whose saved identity has been deleted.
	///
	/// Diagnostics, not cleanup: removing the reference would erase the evidence that this app was
	/// originally signed with another key, and deleting a profile row is the user's decision.
	func orphanedBundleIDs(available: Set<String>? = nil) -> [String] {
		let uuids = available ?? Set(Storage.shared.getAllCertificates().compactMap { $0.uuid?.lowercased() })
		return all
			.filter { _, profile in
				Self.resolveIdentity(captured: profile.certificateUUID, available: uuids).isOrphaned
			}
			.keys
			.sorted()
	}
}
