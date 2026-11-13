//
//  SignatureVerifier.swift
//  VexSign
//
//  Post-sign inspection of a bundle VexSign has just produced.
//
//  Nothing here re-derives a signature or recomputes hashes over the whole bundle: that
//  would cost seconds on a large app and duplicate what installd does anyway. It answers a
//  narrower and still useful question — "is what landed on disk the thing we meant to make?"
//  — using structural evidence that is cheap to read:
//
//    * the main executable and every nested Mach-O carry an LC_CODE_SIGNATURE load command;
//    * `_CodeSignature/CodeResources` exists where the bundle says it is signed;
//    * the profile the bundle embeds is the one that covers its bundle identifier;
//    * the entitlements sealed into the executable are granted by that profile;
//    * the profile has not expired.
//
//  Unknown evidence remains a warning. Definite structural/profile mismatches are
//  failures and must stop a freshly signed bundle from being registered as successful.
//  This is structural inspection, not cryptographic or on-device acceptance.
//

import Foundation
import NimbleExtensions

// MARK: - Verifier

enum SignatureVerifier {
	// MARK: Issue

	struct Issue: Identifiable, Equatable {
		enum Severity: String, Equatable {
			case warning
			case failure
		}

		enum Code: String, Equatable {
			case bundleNotFound
			case executableMissing
            case bundleIdentifierMissing
			case missingCodeResources
			case unsignedExecutable
			case unsignedNestedBundle
			case profileMissing
			case profileUnreadable
			case profileExpired
			/// The certificate that actually signed the bundle is past its `notAfter`.
			case certificateExpired
			case profileIdentifierUnknown
			case bundleIdentifierMismatch
            case requestedIdentifierMismatch
			case nestedIdentifierUncovered
			case entitlementUnreadable
			case entitlementNotGranted
		}

		let code: Code
		let severity: Severity
		/// User-facing, and it says what is wrong rather than which enum case fired.
		let detail: String
		/// The file or key the issue is about, when there is one — so a caller can group or
		/// count issues without parsing `detail`.
		var subject: String?

		var id: String {
			"\(code.rawValue):\(detail)"
		}
	}

	// MARK: Report

	struct Report: Equatable {
		let bundlePath: String?
		let issues: [Issue]
		let duration: TimeInterval

        struct Rejection: LocalizedError {
            let errorDescription: String?
        }

        /// Every failure stops the run, whether or not the user chose "Sign Anyway".
        ///
        /// The override used to excuse an expired profile, an App ID that does not include
        /// the bundle, an uncovered nested bundle and an entitlement the profile does not
        /// grant. iOS refuses to install a bundle in any of those states, so keeping it
        /// registered a signed copy that could not be installed. "Sign Anyway" now applies
        /// only to preflight findings that do not invalidate the result; the parameter
        /// stays so callers keep one spelling for both stages.
        func stopsRun(overridingBlockingIssues: Bool) -> Bool {
            guard bundlePath != nil else { return true }
            return !failures.isEmpty
        }

        func requireAcceptable(overridingBlockingIssues: Bool = false) throws {
            guard stopsRun(overridingBlockingIssues: overridingBlockingIssues) else { return }
            throw Rejection(errorDescription: summary)
        }

		/// The result as one of a fixed set of answers, for a caller that has to decide
		/// what it may say about the bundle.
		enum Verdict: String, Equatable {
			/// Every check ran and none failed.
			case valid
			/// At least one check failed. The bundle is not kept.
			case invalid
			/// Nothing failed, but part of the evidence could not be read, so the checks
			/// that depend on it did not run.
			case incomplete
			/// There was no bundle to inspect.
			case unsupported

			/// Only `valid` may be described as verified.
			var isVerified: Bool { self == .valid }
		}

		/// Codes that mean "this could not be read", as opposed to "this is wrong".
		private static let evidenceGaps: Set<Issue.Code> = [
			.profileUnreadable, .profileIdentifierUnknown, .entitlementUnreadable
		]

		var verdict: Verdict {
			guard bundlePath != nil else { return .unsupported }
			if !failures.isEmpty { return .invalid }
			return warnings.contains { Self.evidenceGaps.contains($0.code) } ? .incomplete : .valid
		}

		var failures: [Issue] {
			issues.filter { $0.severity == .failure }
		}

		var warnings: [Issue] {
			issues.filter { $0.severity == .warning }
		}

		/// A bundle with no bundle is not acceptable; one with no failures is.
		var isAcceptable: Bool {
			bundlePath != nil && failures.isEmpty
		}

		var summary: String {
			guard bundlePath != nil else {
				return .localized("No app bundle to verify.")
			}

			let elapsed = Int64((duration * 1000).rounded())
			if isAcceptable {
				if warnings.isEmpty {
					return .localized("Signature structure checked in %lld ms.", arguments: elapsed)
				}
				return .localized(
					"Signature structure checked in %lld ms with %lld warning(s).",
					arguments: elapsed, Int64(warnings.count)
				)
			}

			return .localized(
				"Signature check found %lld problem(s): %@",
				arguments: Int64(failures.count), failures.map(\.detail).joined(separator: " ")
			)
		}
	}

	// MARK: Expectation

	/// What the caller believes it just produced. Verification is only meaningful relative to
	/// that: a bundle signed with `removeProvisioning` has no profile on purpose.
	struct Expectation {
		/// False for a modify-only run, where nothing was signed and nothing should be expected.
		var expectsSignature: Bool
		/// False when the caller deliberately strips the profile, or is checking a bundle
		/// signed elsewhere (which may be ad-hoc and profile-free).
		var requiresEmbeddedProfile: Bool
		/// The identifier the user asked for, when there is one. A mismatch with the produced
		/// bundle means the signing options did not take effect.
		var declaredBundleIdentifier: String?
		/// Whether this bundle was signed by *this* run, so its signer is ours to judge.
		///
		/// False when checking a bundle signed elsewhere. Such an app may legitimately carry
		/// an expired signing certificate — iOS accepts a signature made while the
		/// certificate was valid — and "install without signing" must not be blocked for it.
		var expectsFreshSignature: Bool

		static let freshlySigned = Expectation(
			expectsSignature: true,
			requiresEmbeddedProfile: true,
			declaredBundleIdentifier: nil,
			expectsFreshSignature: true
		)

		static let alreadySigned = Expectation(
			expectsSignature: true,
			requiresEmbeddedProfile: false,
			declaredBundleIdentifier: nil,
			expectsFreshSignature: false
		)
	}

	// MARK: Keys

	/// Entitlements that are rewritten on purpose by VexSign itself, or that iOS derives
	/// rather than validates against the profile's list. A difference here is worth saying
	/// out loud, but it is not proof the app will fail — and every one of these would
	/// otherwise block a bundle that installs perfectly well.
	/// Shared with `ProfileCompatibility`, which must not block on the same keys for the same
	/// reason: a preflight that disagrees with the verifier is a preflight nobody trusts.
	static var tolerantEntitlementKeys: Set<String> {
		Set(
			[
				"application-identifier",
				"com.apple.application-identifier",
				"com.apple.developer.team-identifier",
				"get-task-allow",
				"keychain-access-groups"
			] + EntitlementBuilder.jitEntitlementKeys
		)
	}

	/// Every folder the signed tree can hold nested code in.
	///
	/// `Watch` belongs here because the pinned engine signs by *path suffix*, not by folder name:
	/// `ZBundle::GetObjectsToSign` recurses the whole tree into any `.app`/`.appex`/`.framework`/
	/// `.xctest` it finds (`Vendor/Zsign/src/bundle.cpp:81-100`), so a retained `Watch/*.app` is
	/// signed exactly like a PlugIn — and `_removeWatchIfNeeded` keeps every watch app that has an
	/// Info.plist. `NestedBundleAudit` already scans `Watch` for profile coverage ("Watch apps ...
	/// remain in the target and must still be covered"). Without it here, the post-sign report was
	/// blind to the one nested bundle that both of those steps treat as load-bearing: an uncovered
	/// or unsigned watch companion verified clean, then failed on the device with nothing in the
	/// log to explain why.
	private static let nestedBundleFolders = ["Frameworks", "PlugIns", "Extensions", "Watch"]
	private static let nestedBundleExtensions: Set<String> = ["framework", "appex", "app", "bundle"]

	// MARK: Verify

	static func verify(bundleAt url: URL, expectation: Expectation = .freshlySigned) -> Report {
		let started = Date()
		var issues: [Issue] = []

		guard let bundleURL = _bundleURL(at: url), let info = readInfo(at: bundleURL) else {
			issues.append(
				Issue(
					code: .bundleNotFound,
					severity: .failure,
					detail: .localized("No .app bundle found in this directory.")
				)
			)
			return Report(bundlePath: nil, issues: issues, duration: Date().timeIntervalSince(started))
		}

        // Bundle caches metadata by path, including the identifier read before
        // modification. Inspect the current plist bytes, not that cached object.
        let producedIdentifier = info["CFBundleIdentifier"] as? String
        if producedIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            issues.append(Issue(code: .bundleIdentifierMissing, severity: .failure,
                detail: .localized("The bundle has no usable bundle identifier.")))
        }
        let executable = SigningInputValidation.executable(in: bundleURL)
		if executable == nil {
			issues.append(
				Issue(
					code: .executableMissing,
					severity: .failure,
					detail: .localized("The bundle does not name an executable.")
				)
			)
		}

		if expectation.expectsSignature {
			issues += _signatureIssues(in: bundleURL, executable: executable, expectation: expectation)
		}

		issues += _profileIssues(
			in: bundleURL,
            producedIdentifier: producedIdentifier,
			executable: executable,
			expectation: expectation
		)

		return Report(bundlePath: bundleURL.path, issues: issues, duration: Date().timeIntervalSince(started))
	}

	// MARK: Signature

	private static func _signatureIssues(
		in bundleURL: URL,
		executable: URL?,
		expectation: Expectation
	) -> [Issue] {
		var issues: [Issue] = []
		let codeResources = bundleURL.appendingPathComponent("_CodeSignature/CodeResources")
        let resourceValues = try? codeResources.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey, .isSymbolicLinkKey]) // try? ok: missing/unreadable signature resources are a verification failure.
        if resourceValues?.isRegularFile != true || resourceValues?.isReadable != true || resourceValues?.isSymbolicLink == true {
			issues.append(
				Issue(
					code: .missingCodeResources,
					severity: .failure,
					detail: .localized("Missing _CodeSignature/CodeResources — the bundle was not signed.")
				)
			)
		}

		if let executable, !MachOEntitlements.hasCodeSignature(forExecutableAt: executable) {
			issues.append(
				Issue(
					code: .unsignedExecutable,
					severity: .failure,
					detail: .localized("The main executable carries no code signature.")
				)
			)
		}

		// The certificate in the signature, not the stored row.
		//
		// `SigningIdentityPolicy` refuses an identity the library already knows is expired, but
		// the row is a cache written at import: a certificate that lapsed since then, or one
		// whose row never carried a date, is still caught here because this reads the real
		// X.509 `notAfter` out of the CMS blob zsign produced. Without it, the run reported
		// success and the app failed at install with an error that names the signature only.
		if expectation.expectsFreshSignature {
			let expiry = BundleSignature.read(bundleAt: bundleURL).expiresAt
			if let issue = certificateExpiryIssue(signatureExpiry: expiry) {
				issues.append(issue)
			}
		}

		// A nested bundle without its own signature fails the whole install, but report it as a
		// warning: zsign's handling of some third-party frameworks is outside VexSign's control,
		// and owns the per-extension profile story.
		for nested in _nestedBundles(in: bundleURL) {
			let isSigned = Bundle(url: nested)
				.flatMap(\.executableURL)
				.map { MachOEntitlements.hasCodeSignature(forExecutableAt: $0) } ?? false

			guard !isSigned else { continue }

			issues.append(
				Issue(
					code: .unsignedNestedBundle,
					severity: .warning,
					detail: .localized("%@ has no code signature.", arguments: nested.lastPathComponent),
					subject: nested.lastPathComponent
				)
			)
		}

		return issues
	}

	/// The certificate-expiry decision on its own, so it can be tested without building a CMS.
	///
	/// - Parameters:
	///   - signatureExpiry: the soonest `notAfter` in the produced signature, or nil when the
	///     signature carries no certificate (ad-hoc) or could not be read.
	///   - now: injected for the boundary test.
	static func certificateExpiryIssue(signatureExpiry: Date?, now: Date = Date()) -> Issue? {
		guard let signatureExpiry, signatureExpiry <= now else { return nil }
		return Issue(
			code: .certificateExpired,
			severity: .failure,
			detail: .localized(
				"The signing certificate expired on %@.",
				arguments: signatureExpiry.formatted(date: .abbreviated, time: .shortened)
			)
		)
	}

	// MARK: Profile

	private static func _profileIssues(
		in bundleURL: URL,
        producedIdentifier: String?,
		executable: URL?,
		expectation: Expectation
	) -> [Issue] {
		var issues: [Issue] = []
		let profileURL = bundleURL.appendingPathComponent("embedded.mobileprovision")
		let hasProfile = FileManager.default.fileExists(atPath: profileURL.path)

		if !hasProfile && expectation.requiresEmbeddedProfile {
			issues.append(
				Issue(
					code: .profileMissing,
					severity: .failure,
					detail: .localized("The bundle has no embedded.mobileprovision.")
				)
			)
		}

		// The identifier the app actually ended up with is checked whether or not a profile is
		// embedded: if the signing options asked for one and the bundle says another, something
		// in between ignored the instruction.
		if let declared = expectation.declaredBundleIdentifier, !declared.isEmpty, declared != producedIdentifier {
			issues.append(
				Issue(
					code: .requestedIdentifierMismatch,
					severity: .failure,
					detail: .localized(
						"Asked for bundle identifier %@ but the bundle says %@.",
						arguments: declared, producedIdentifier ?? .localized("nothing")
					)
				)
			)
		}

		guard hasProfile else {
			return issues
		}

		guard let profile = CertificateReader(profileURL).decoded else {
			issues.append(
				Issue(
					code: .profileUnreadable,
					severity: .warning,
					detail: .localized("Could not read the embedded profile, so its contents were not checked.")
				)
			)
			return issues
		}

		if profile.ExpirationDate < Date() {
			issues.append(
				Issue(
					code: .profileExpired,
					severity: .failure,
					detail: .localized(
						"The embedded profile expired on %@.",
						arguments: profile.ExpirationDate.formatted(date: .abbreviated, time: .shortened)
					)
				)
			)
		}

		let profileEntitlements = profile.Entitlements.map { $0.mapValues { $0.value } } ?? [:]

		if let pattern = profileEntitlements["application-identifier"] as? String {
			if let producedIdentifier, !coverage(of: pattern, includes: producedIdentifier) {
				issues.append(
					Issue(
						code: .bundleIdentifierMismatch,
						severity: .failure,
						detail: .localized(
							"The profile covers %@ but the app is %@.",
							arguments: pattern, producedIdentifier
						)
					)
				)
			}

			issues += _nestedIdentifierIssues(in: bundleURL, pattern: pattern, appIdentifier: producedIdentifier)
		} else {
			issues.append(
				Issue(
					code: .profileIdentifierUnknown,
					severity: .warning,
					detail: .localized("The profile does not state which app identifier it covers.")
				)
			)
		}

		if let executable {
			issues += _entitlementIssues(
				signed: MachOEntitlements.read(forExecutableAt: executable),
				granted: profileEntitlements
			)
		}

		return issues
	}

	private static func _nestedIdentifierIssues(
		in bundleURL: URL,
		pattern: String,
		appIdentifier: String?
	) -> [Issue] {
		var issues: [Issue] = []

		for nested in _nestedBundles(in: bundleURL) {
			guard
				let identifier = readInfo(at: nested)?["CFBundleIdentifier"] as? String,
				identifier != appIdentifier,
				!coverage(of: pattern, includes: identifier)
			else { continue }

			// A nested bundle signed with a profile of its own carries that profile; what
			// matters then is that *its* profile covers it, not the app's.
			if let own = NestedBundleAudit.shippedProfileIdentifier(at: nested), coverage(of: own, includes: identifier) {
				continue
			}

			issues.append(
				Issue(
					code: .nestedIdentifierUncovered,
                    severity: .failure,
					detail: .localized(
						"%@ (%@) is not covered by the embedded profile.",
						arguments: nested.lastPathComponent, identifier
					),
					subject: nested.lastPathComponent
				)
			)
		}

		return issues
	}

	// MARK: Entitlements

	private static func _entitlementIssues(signed: [String: Any]?, granted: [String: Any]) -> [Issue] {
		guard let signed, !signed.isEmpty else {
			return [
				Issue(
					code: .entitlementUnreadable,
					severity: .warning,
					detail: .localized("Could not read the entitlements sealed into the executable.")
				)
			]
		}

		var issues: [Issue] = []

		for (key, value) in signed.sorted(by: { $0.key < $1.key }) {
			let severity: Issue.Severity = tolerantEntitlementKeys.contains(key) ? .warning : .failure

			guard let grantedValue = granted[key] else {
				issues.append(
					Issue(
						code: .entitlementNotGranted,
						severity: severity,
						detail: .localized("The profile does not grant %@.", arguments: key)
					)
				)
				continue
			}

			if let signedArray = value as? [Any] {
				// A subset is fine: the profile may grant more than this app asks for. Only an
				// element the profile never grants is a problem.
				let grantedElements = Set((grantedValue as? [Any] ?? []).map { _describe($0) })
				let missing = signedArray
					.compactMap { $0 as? String }
					.filter { !grantedElements.contains($0) }

				if !missing.isEmpty {
					issues.append(
						Issue(
							code: .entitlementNotGranted,
							severity: severity,
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
						severity: severity,
						detail: .localized(
							"%@ is signed as %@ but the profile grants %@.",
							arguments: key, _describe(value), _describe(grantedValue)
						)
					)
				)
			}
		}

		return issues
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

	// MARK: Identifiers

	/// Whether a profile's `application-identifier` (`TEAMID.bundle.id` or `TEAMID.*`) covers an
	/// identifier, using Apple's wildcard rules.
	///
	/// The team prefix is *not* part of a bundle identifier, so it cannot be compared here: a
	/// bundle id is `com.foo.bar`, not `TEAMID.com.foo.bar`. Entitlement values do carry it, so
	/// both shapes are accepted. Team identity is a separate question — see
	/// `ProfileCompatibility`, which compares team IDs directly.
	static func coverage(of pattern: String, includes identifier: String) -> Bool {
		// A value with no prefix is not an App ID; it is compared literally, as before.
		guard pattern.contains(".") else { return pattern == identifier }

		if ProfileApplicationIdentifierMatcher.match(
			applicationIdentifier: pattern, bundleIdentifier: identifier
		).isAuthorized {
			return true
		}
		// The same question asked with a signed entitlement value, which carries the prefix.
		return ProfileApplicationIdentifierMatcher.match(
			applicationIdentifier: pattern, entitlementValue: identifier
		).isAuthorized
	}

	/// True when a profile's `application-identifier` is a wildcard App ID rather than one
	/// app. A malformed value is not a wildcard.
	static func isWildcard(_ pattern: String) -> Bool {
		guard case .success(let authorized) = ProfileApplicationIdentifierMatcher.parse(pattern) else { return false }
		return authorized.isWildcard
	}

	// MARK: File system

    /// Read mutable bundle metadata without Foundation's per-path Bundle cache.
    static func readInfo(at bundleURL: URL) -> [String: Any]? {
        do {
            let data = try Data(contentsOf: bundleURL.appendingPathComponent("Info.plist"))
            let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            return object as? [String: Any]
        } catch {
            // Unreadable metadata is represented by a blocking verifier failure,
            // not a cached fallback or a successful empty-plist interpretation.
            return nil
        }
    }

	private static func _bundleURL(at url: URL) -> URL? {
		let fm = FileManager.default

		if url.pathExtension == "app" {
			var isDirectory: ObjCBool = false
			if fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
				return url
			}
		}

		guard
			let contents = try? fm.contentsOfDirectory(
				at: url,
				includingPropertiesForKeys: [.isDirectoryKey],
				options: [.skipsHiddenFiles]
			)
		else {
			return nil
		}

		return contents
			.filter { $0.pathExtension == "app" }
			.sorted { $0.lastPathComponent < $1.lastPathComponent }
			.first
	}

	private static func _nestedBundles(in bundleURL: URL) -> [URL] {
		let fm = FileManager.default
		var nested: [URL] = []

		for folder in nestedBundleFolders {
			let directory = bundleURL.appendingPathComponent(folder)
			guard
				let contents = try? fm.contentsOfDirectory(
					at: directory,
					includingPropertiesForKeys: [.isDirectoryKey],
					options: [.skipsHiddenFiles]
				)
			else { continue }

			nested += contents.filter { nestedBundleExtensions.contains($0.pathExtension.lowercased()) }
		}

		return nested.sorted { $0.lastPathComponent < $1.lastPathComponent }
	}
}
