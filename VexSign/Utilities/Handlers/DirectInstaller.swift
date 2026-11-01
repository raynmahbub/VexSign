//
//  DirectInstaller.swift
//  VexSign
//
//  Installs a bundle that is already signed — an IPA from another tool, a
//  distribution server, or a previous VexSign export — without running it through
//  Zsign again. Re-signing an already-signed app with a different identity breaks
//  its keychain access groups and app groups, so "install as-is" is the correct
//  path for those.
//
//  The bundle is verified first: `_CodeSignature` plus a code signature load
//  command on the main executable. installd makes the final call; this check only
//  stops the obviously-unsigned cases before a two-minute OTA dance.
//

import Foundation
import NimbleExtensions
import OSLog

// MARK: - Result

struct DirectInstallVerification: Equatable {
	let bundlePath: String?
	let hasSignatureDirectory: Bool
	let hasSignedExecutable: Bool
	let unsignedNestedBundles: [String]
	/// The full result of the shared verifier. The three flags above predate it and are kept
	/// because callers and tests read them; this is the complete picture.
	var report: SignatureVerifier.Report?

	var isSigned: Bool {
		bundlePath != nil && hasSignatureDirectory && hasSignedExecutable
	}

	/// What the verifier is sure is wrong. Installing past these means waiting out an install
	/// that installd will reject.
	var blockingIssues: [String] {
		report?.failures.map(\.detail) ?? []
	}

	var hasBlockingIssues: Bool {
		!blockingIssues.isEmpty
	}

	/// Human-readable reasons, shown before the install is offered.
	var issues: [String] {
		if let report, !report.issues.isEmpty {
			return report.issues.map(\.detail)
		}

		// No bundle at all: the rest of the checks have nothing to look at.
		guard bundlePath != nil else {
			return [String.localized("No .app bundle found in this directory.")]
		}

		var issues: [String] = []
		if !hasSignatureDirectory {
			issues.append(String.localized("Missing _CodeSignature — the app was never signed."))
		}
		if !hasSignedExecutable {
			issues.append(String.localized("The main executable has no code signature."))
		}
		for name in unsignedNestedBundles {
			issues.append(String.localized("%@ has no _CodeSignature.", arguments: name))
		}
		return issues
	}
}

// MARK: - Installer

@MainActor
final class DirectInstaller {
	static let shared = DirectInstaller()

	enum DirectInstallError: LocalizedError {
		case appNotFound
		case notSigned([String])
		/// Signed, but the post-sign checks found something installd will reject. The caller
		/// may offer to install anyway, naming these.
		case verificationFailed([String])

		var errorDescription: String? {
			switch self {
			case .appNotFound:
				String.localized("App files not found.")
			case .notSigned(let issues):
				String.localized("This app isn't signed:\n%@", arguments: issues.joined(separator: "\n"))
			case .verificationFailed(let issues):
				String.localized("This app has a signature problem:\n%@", arguments: issues.joined(separator: "\n"))
			}
		}
	}

	private init() {}

	// MARK: Verification

	/// Checks a library entry's bundle on disk.
	func verify(_ app: AppInfoPresentable) -> DirectInstallVerification {
		guard let directory = Storage.shared.getAppDirectory(for: app) else {
			return DirectInstallVerification(
				bundlePath: nil,
				hasSignatureDirectory: false,
				hasSignedExecutable: false,
				unsignedNestedBundles: []
			)
		}
		return Self.verify(directory: directory)
	}

	/// Checks an unpacked app directory (…/<uuid>/ or the .app itself) with the shared
	/// verifier, so "install without signing" and "I just signed this" follow the same rules.
	nonisolated static func verify(directory: URL) -> DirectInstallVerification {
		let report = SignatureVerifier.verify(bundleAt: directory, expectation: .alreadySigned)

		guard let bundlePath = report.bundlePath else {
			return DirectInstallVerification(
				bundlePath: nil,
				hasSignatureDirectory: false,
				hasSignedExecutable: false,
				unsignedNestedBundles: [],
				report: report
			)
		}

		let failures = Set(report.failures.map(\.code))

		return DirectInstallVerification(
			bundlePath: bundlePath,
			hasSignatureDirectory: !failures.contains(.missingCodeResources),
			hasSignedExecutable: !failures.contains(.unsignedExecutable) && !failures.contains(.executableMissing),
			unsignedNestedBundles: report.warnings
				.filter { $0.code == .unsignedNestedBundle }
				.compactMap(\.subject),
			report: report
		)
	}

	// MARK: Install

	/// Verifies, then hands the app to the normal install queue (OTA or idevice,
	/// exactly like a freshly signed app).
	/// - Parameter allowingIssues: set only after the user has been shown the failing checks
	///   and chosen to go ahead. It never bypasses "there is no signature at all".
	@discardableResult
	func install(_ app: AppInfoPresentable, allowingIssues: Bool = false) throws -> DirectInstallVerification {
		let verification = verify(app)

		guard verification.bundlePath != nil else { throw DirectInstallError.appNotFound }
		guard verification.isSigned else { throw DirectInstallError.notSigned(verification.issues) }

		if !allowingIssues, verification.hasBlockingIssues {
			throw DirectInstallError.verificationFailed(verification.blockingIssues)
		}

		InstallQueue.shared.enqueue(app)
		Logger.misc.info("Direct install queued for \(app.identifier ?? "unknown")")
		return verification
	}
}
