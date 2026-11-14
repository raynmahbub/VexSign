//
//  SignatureVerifier.swift
//  VexSign
//
//  Post-sign inspection of a bundle VexSign has just produced.
//
//  Fresh device-signing output is admitted only after independent per-image
//  CodeDirectory/page/special-slot/CMS and resource-envelope verification against
//  the exact authenticated component plan. Import-only inspection is explicitly
//  structural evidence and is never described as cryptographically verified.
//  Neither result is a claim that a physical device accepted installation.
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
            case manifestInvalid, expectedAssetsMissing, signatureInvalid, resourceSealInvalid
            case signerMismatch, profileChanged, inspectionOnly
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

        /// Import inspection may be incomplete. Fresh device-signing output may
        /// not be registered on that weaker result, even with a preflight override.
        func requireVerified() throws {
            try requireAcceptable()
            guard verdict.isVerified else {
                throw Rejection(errorDescription: .localized("Fresh signing verification is incomplete. Import a complete IPA and compatible current signing assets; this output has not been registered."))
            }
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
			.profileUnreadable, .profileIdentifierUnknown, .entitlementUnreadable, .inspectionOnly
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

    /// What the caller produced. Device-signing acceptance requires authenticated
    /// per-component assets and embedded profiles; import/ad-hoc inspection must
    /// never be promoted to fresh device-signature acceptance.
	struct Expectation {
		/// False for a modify-only run, where nothing was signed and nothing should be expected.
		var expectsSignature: Bool
        /// False only for inspection of imported/ad-hoc/modify-only output, not
        /// permission to omit profiles from fresh device-signing output.
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
        var assets: [String: AssetExpectation] = [:]

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

    /// No requested security capability is merely tolerated. A changed identity
    /// is planned before signing and independently authorized by its own profile.
    static var tolerantEntitlementKeys: Set<String> { [] }

    // Both fresh and imported inspection discover nested code through SigningPlan.
    // There is no folder allowlist that could hide a deeper extension/framework.

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

        if expectation.expectsSignature && expectation.expectsFreshSignature {
            if let declared = expectation.declaredBundleIdentifier, declared != producedIdentifier {
                issues.append(.init(code: .requestedIdentifierMismatch, severity: .failure,
                    detail: "The produced Bundle Identifier differs from the explicit signing request."))
            }
            issues += freshSealIssues(in: bundleURL, assets: expectation.assets)
            return Report(bundlePath: bundleURL.path, issues: issues, duration: Date().timeIntervalSince(started))
        }
        if expectation.expectsSignature {
            issues.append(.init(code: .inspectionOnly, severity: .warning,
                detail: "This imported signature was structurally inspected, not authenticated against a VexSign signing plan. Device installation and trust have not been established."))
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

        // Structural failures remain blocking even for imported signatures. The
        // inspectionOnly warning still prevents any cryptographic trust claim.
		for nested in _nestedBundles(in: bundleURL) {
            let isSigned = SigningInputValidation.executable(in: nested)
				.map { MachOEntitlements.hasCodeSignature(forExecutableAt: $0) } ?? false

			guard !isSigned else { continue }

			issues.append(
				Issue(
					code: .unsignedNestedBundle,
					severity: .failure,
                    detail: .localized("%@ has no code signature.", arguments: nested.lastPathComponent),
					subject: nested.lastPathComponent
				)
			)
		}

        let plan = SigningPlan.make(appBundle: bundleURL)
        for issue in plan.validationIssues() where issue.severity == .blocking {
            issues.append(.init(code: .manifestInvalid, severity: .failure, detail: issue.detail))
        }
        for component in plan.components where component.kind == .dylib {
            if !MachOEntitlements.hasCodeSignature(forExecutableAt: bundleURL.appendingPathComponent(component.path)) {
                issues.append(.init(code: .unsignedExecutable, severity: .failure,
                    detail: component.path + " has no readable code signature.", subject: component.path))
            }
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
					severity: .failure,
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

        for component in SigningPlan.make(appBundle: bundleURL).profileBoundComponents {
            let nested = bundleURL.appendingPathComponent(component.path)
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
        guard let signed else {
            return [.init(code: .entitlementUnreadable, severity: .failure,
                detail: .localized("Could not read the entitlements sealed into the executable."))]
        }
        return ProfileEntitlementAuthorization.failures(requested: signed, grants: granted).map { key in
            .init(code: .entitlementNotGranted, severity: .failure,
                detail: .localized("The profile does not grant %@.", arguments: key))
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
            let data = try CertificateInputReader.read(bundleURL.appendingPathComponent("Info.plist"))
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

		if url.pathExtension.lowercased() == "app" {
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
			.filter { $0.pathExtension.lowercased() == "app" }
			.sorted { $0.lastPathComponent < $1.lastPathComponent }
			.first
	}

    private static func _nestedBundles(in bundleURL: URL) -> [URL] {
        SigningPlan.make(appBundle: bundleURL).components
            .filter { $0.kind != .dylib && !$0.isResourceOnly }
            .map { bundleURL.appendingPathComponent($0.path) }
    }
}
