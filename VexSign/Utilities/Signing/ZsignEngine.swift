//
//  ZsignEngine.swift
//  VexSign
//
//  The single seam between VexSign and the bundled `zsign` engine.
//
//  The engine is not a Swift-native dependency: it is the vendored `Vendor/Zsign` package
//  (upstream `claration/Zsign-Package`, branch `package`, commit pinned in Vendor/manifest.json).
//  Every signing run goes through this type — the bundle it signs, the flag it hands over, the
//  cache it leaves behind — so the pin's quirks are documented and owned in one place instead of
//  being spread over the handlers that happen to call it. (`TweakHandler` still calls the wrapper
//  directly for dylib surgery, and `Storage+Certificate` for revocation checks; neither signs.)
//
//  Two of those quirks are load-bearing:
//
//  1. Provisioning polarity. The Swift wrapper's `removeProvision:` lands in the C++ entry as
//     `excludeProvisioning`, and in the pinned engine that flag **writes** the profile when it
//     is `true` (`Vendor/Zsign/src/bundle.cpp:536-544`) and deletes it without writing anything when it is
//     `false`. VexSign's own `Options.removeProvisioning` means the opposite, so the intent is
//     translated exactly once, in `Request.engineEmbedProvision`.
//
//  2. The working directory. Every path the engine is handed is used relative to the process
//     CWD, and so is the cache it writes (`./.zsign_cache/<sha1 of app folder>.json`,
//     `src/bundle.cpp:556-596`). The pin hardcodes `bForce = true` alongside
//     `bEnableCache = true`, which means the cache is written but never read back — see
//     `clearCache(in:)`.
//

import Foundation
import NimbleExtensions
import ZsignSwift

/// The pinned signing engine, addressed in VexSign's terms.
enum ZsignEngine {
	/// Name of the cache directory the engine creates next to its working directory.
	static let cacheDirectoryName = ".zsign_cache"

	// MARK: - Request

	/// One signing run. Paths are passed to the engine as-is, which resolves them against the
	/// process working directory.
	struct Request: Equatable {
		/// Path to the `.app` bundle that is signed in place.
		var appPath: String
		/// Provisioning profile to embed.
		var provisionPath: String = ""
		/// `.p12` identity the bundle is signed with.
		var p12Path: String = ""
		var p12Password: String = ""
		/// Entitlements the identity is allowed to grant. Empty falls back to the profile's.
		var entitlementsPath: String = ""
		/// Optional `CFBundleIdentifier` / display name / version rewrites.
		var customIdentifier: String = ""
		var customName: String = ""
		var customVersion: String = ""
		/// Ad-hoc signing: the engine signs without an identity.
		var isAdHoc: Bool = false
		/// User intent, straight from `Options.removeProvisioning`: leave no profile behind.
		var removeProvisioning: Bool = false

		/// The value the pinned engine expects for `removeProvisioning`.
		///
		/// Same side, opposite name: the pin writes `embedded.mobileprovision` when its flag is
		/// `true` and leaves the bundle without one when it is `false`, so the flag is "embed",
		/// not "remove". `SignatureVerificationExpectation.requiresEmbeddedProfile`
		/// (`SigningHandler.swift`) is derived from the same option, which keeps what the signer
		/// does and what the verifier demands in step — if one of them ever changes, this
		/// translation and `ZU.signsWithEmbeddedProfile` in the tests have to change with it.
		var engineEmbedProvision: Bool { !removeProvisioning }
	}

	/// What a run reports back: the engine's own bool, and the error it filled in, if any.
	struct Outcome: Equatable {
		let succeeded: Bool
		/// The engine surfaces a message but no type of its own; the message is kept verbatim.
		let errorMessage: String?
	}

	// MARK: - Identity

	/// Why the pinned engine would refuse to *start* a run, in VexSign's words.
	///
	/// `zsign.mm` returns -1 **without invoking its completion handler** when
	/// `ZSignAsset::Init` fails, so `Outcome` arrives as `succeeded == false,
	/// errorMessage == nil` and the only trace is a `ZLog` line on stdout. 1.0 discarded the
	/// returned bool, which is why a profile that does not belong to the .p12 used to report
	/// "Signed successfully"; reporting it without saying why is the other half of the same
	/// bug, and it is what `SigningFileHandlerError.signFailed` ("Signing failed.") did.
	///
	/// These cases mirror `ZSignAsset::Init` (`Vendor/Zsign/src/openssl.cpp`, "Identity"):
	/// it reads the profile, requires a team id, opens the .p12 with the password, and
	/// requires the .p12's certificate to be one the profile names.
	enum IdentityProblem: Equatable {
		case missingProvisioningProfile
		case missingCertificate
		case profileUnreadable
		case unreadableCertificate
		case missingTeamIdentifier
		case certificateNotInProfile

		/// Says what is wrong *and* what to do about it.
		var message: String {
			switch self {
			case .missingProvisioningProfile:
				.localized("This certificate has no provisioning profile on disk. Import the profile that came with the .p12.")
			case .missingCertificate:
				.localized("This certificate has no .p12 on disk. Import it again from Settings → Certificates.")
			case .profileUnreadable:
				.localized("The provisioning profile could not be read. Import it again; it may be truncated or not a .mobileprovision.")
			case .unreadableCertificate:
				.localized("The .p12 could not be opened with the password saved for this certificate. Re-import the certificate with its password.")
			case .missingTeamIdentifier:
				.localized("The provisioning profile does not name an Apple team, so the engine cannot use it. Import a profile issued by Apple.")
			case .certificateNotInProfile:
				.localized("The provisioning profile was not issued for this certificate. Import the profile that belongs to the .p12, or select the certificate that profile names.")
			}
		}
	}

	/// The reason the engine would refuse this identity, or nil when it looks acceptable.
	///
	/// Pure and cheap: it reads what the caller already has on disk, and answers the same
	/// question `ZSignAsset::Init` answers a moment later — just with a sentence attached.
	static func identityProblem(
		provisioningProfile: Data?,
		certificate: Data?,
		leafCertificate: Data?,
		profile: Certificate?
	) -> IdentityProblem? {
		guard let provisioningProfile, !provisioningProfile.isEmpty else { return .missingProvisioningProfile }
		guard let certificate, !certificate.isEmpty else { return .missingCertificate }
		guard let profile else { return .profileUnreadable }
		guard let team = profile.TeamIdentifier.first, !team.isEmpty else { return .missingTeamIdentifier }

		// A .p12 that opens with the stored password always yields its leaf certificate; when
		// that is nil, either the password is wrong or the file is not a PKCS#12 at all.
		guard let leafCertificate, !leafCertificate.isEmpty else {
			return .unreadableCertificate
		}

		let named = (profile.DeveloperCertificates ?? []).map { SigningIdentity.fingerprint(of: $0) }
		guard named.isEmpty || named.contains(SigningIdentity.fingerprint(of: leafCertificate)) else {
			return .certificateNotInProfile
		}
		return nil
	}

	// MARK: - Signing

	/// Signs one bundle. Blocking — call it off the main actor.
	static func sign(_ request: Request) -> Outcome {
		var engineError: Error?

		let success = Zsign.sign(
			appPath: request.appPath,
			provisionPath: request.provisionPath,
			p12Path: request.p12Path,
			p12Password: request.p12Password,
			entitlementsPath: request.entitlementsPath,
			customIdentifier: request.customIdentifier,
			customName: request.customName,
			customVersion: request.customVersion,
			adhoc: request.isAdHoc,
			removeProvision: request.engineEmbedProvision,
			completion: { _, error in
				engineError = error
			}
		)

		// The wrapper reports failure two ways: the returned bool, and the error the engine
		// hands to its completion handler (built from the bundle's failed files). Both are
		// carried out unchanged; the caller treats either as a failed run.
		return Outcome(
			succeeded: success,
			errorMessage: engineError?.localizedDescription
		)
	}

	/// Removes load commands (injected dylibs) from an executable in place.
	///
	/// - Returns: `true` when the executable no longer carries any of `dylibs`.
	static func removeInjectedDylibs(_ dylibs: [String], fromExecutableAt path: String) -> Bool {
		Zsign.removeDylibs(appExecutable: path, using: dylibs)
	}

	// MARK: - Cache

	/// Where the engine keeps its signing cache for a run started from `directory`.
	///
	/// The path comes from the engine's working directory (`./.zsign_cache`), *not* from the
	/// bundle being signed, so two runs from different directories never share an entry — and a
	/// run from a read-only directory (the usual case on a device) simply cannot cache.
	static func cacheDirectory(
		in directory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
	) -> URL {
		directory.appendingPathComponent(cacheDirectoryName, isDirectory: true)
	}

	/// Deletes the engine's cache directory.
	///
	/// The pin enables the cache and hardcodes `bForce = true` in the same call
	/// (`src/zsign.mm:182` and `:218`), so the entry is written on every run and read on none: it
	/// can never produce a cache hit, only litter in the working directory. Clearing it before a
	/// run therefore costs nothing, and stops a stale entry from a previous version of the engine
	/// from being trusted by a future one.
	///
	/// - Returns: `true` when a cache directory was present and removed.
	@discardableResult
	static func clearCache(
		in directory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
	) -> Bool {
		let cacheDirectory = cacheDirectory(in: directory)
		guard FileManager.default.fileExists(atPath: cacheDirectory.path) else {
			return false
		}
		do {
			try FileManager.default.removeItem(at: cacheDirectory)
			return true
		} catch {
			SigningLog.shared.warn(
				"Could not clear the signing cache at \(cacheDirectory.path): \(error.localizedDescription)"
			)
			return false
		}
	}
}
