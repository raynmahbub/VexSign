//
//  PreflightChecks.swift
//  VexSign
//
//  One validation pass before signing starts, so a two-minute sign-and-install cycle
//  fails on the boring data problems first: bundle id / version sanity, missing Info.plist
//  keys, dylib architecture mismatches, duplicate dylib names and an expired certificate.
//
//  Each check returns `PreflightIssue`s; `issues(for:using:)` runs them all.
//

import Foundation
import SwiftUI
import NimbleExtensions

// MARK: - Issue
struct PreflightIssue: Identifiable, Equatable {
	enum Severity: Equatable {
		case warning
		case blocking
	}

	let id: String
	let title: String
	let detail: String
	let severity: Severity

	init(_ title: String, _ detail: String, severity: Severity = .warning) {
		self.id = "\(title)|\(detail)"
		self.title = title
		self.detail = detail
		self.severity = severity
	}
}

// MARK: - Result
struct PreflightResult {
	let issues: [PreflightIssue]

	var hasBlocking: Bool { issues.contains { $0.severity == .blocking } }
	var isEmpty: Bool { issues.isEmpty }
}

// MARK: - Checks
@MainActor
enum PreflightChecks {
	private static let requiredInfoPlistKeys: [(key: String, label: String)] = [
		("CFBundleIdentifier", "Bundle Identifier"),
		("CFBundleName", "Bundle Name"),
		("CFBundleExecutable", "Executable"),
	]

	static func run(app: AppInfoPresentable, options: Options, certificate: CertificatePair?) -> PreflightResult {
		var issues: [PreflightIssue] = []

		bundleIdentifier(app: app, into: &issues)
		versions(app: app, options: options, into: &issues)
		plistKeys(app: app, into: &issues)
		certificateExpiry(certificate: certificate, options: options, into: &issues)
		profileCompatibility(app: app, options: options, certificate: certificate, into: &issues)
		signerIdentity(app: app, options: options, certificate: certificate, into: &issues)
		jitEntitlement(certificate: certificate, options: options, into: &issues)
		dylibInjections(app: app, options: options, into: &issues)

		return PreflightResult(issues: issues)
	}

	// MARK: Bundle identifier

	private static func bundleIdentifier(app: AppInfoPresentable, into issues: inout [PreflightIssue]) {
		guard let id = app.identifier, !id.isEmpty else {
			issues.append(PreflightIssue(
				.localized("Missing bundle identifier"),
				.localized("The app has no bundle identifier, so iOS may reject the install."),
				severity: .blocking
			))
			return
		}

		// Reverse-DNS sanity: at least one dot and no whitespace.
		if !id.contains(".") || id.contains(" ") {
			issues.append(PreflightIssue(
				.localized("Suspicious bundle identifier"),
				String.localized("“%@” does not look like a reverse-DNS identifier (no dots), which can break installed detection and updates.", arguments: id)
			))
		}
	}

	// MARK: Versions

	private static func versions(app: AppInfoPresentable, options: Options, into issues: inout [PreflightIssue]) {
		// The app must have some version the signer can write; loading one is a soft warning.
		guard app.version == nil, options.appVersion == nil else { return }
		issues.append(PreflightIssue(
			.localized("No version"),
			.localized("The app has no short version. It will still sign, but the version shown in Settings may be empty.")
		))
	}

	// MARK: Info.plist keys

	private static func plistKeys(app: AppInfoPresentable, into issues: inout [PreflightIssue]) {
		guard let appDir = Storage.shared.getAppDirectory(for: app) else { return }
		let plist = appDir.appendingPathComponent("Info.plist")

		guard let dict = NSDictionary(contentsOf: plist) else {
			issues.append(PreflightIssue(
				.localized("Unreadable Info.plist"),
				.localized("The app bundle's Info.plist could not be read. Signing may still work, but the app may crash on launch."),
				severity: .blocking
			))
			return
		}

		let missing = requiredInfoPlistKeys.filter { dict[$0.key] == nil }
		for entry in missing {
			issues.append(PreflightIssue(
				.localized("Missing Info.plist key"),
				String.localized("“%@” is missing from the app's Info.plist.", arguments: entry.label),
				severity: .blocking
			))
		}
	}

	// MARK: Certificate expiry

	private static func certificateExpiry(certificate: CertificatePair?, options: Options, into issues: inout [PreflightIssue]) {
		// "Modify only" never needs a certificate.
		guard options.signingOption != .onlyModify else { return }
		guard certificate == nil, options.signingOption == .default else {
			verifyExpiry(certificate, into: &issues)
			return
		}
		// No certificate but default signing → Zsign will fail, surface it earlier.
		issues.append(PreflightIssue(
			.localized("No certificate"),
			.localized("The default signing option needs a certificate; none is selected. Import one in Settings → Certificates."),
			severity: .blocking
		))
	}

	private static func verifyExpiry(_ certificate: CertificatePair?, into issues: inout [PreflightIssue]) {
		guard let expiration = certificate?.expiration else { return }
		guard Date() < expiration else {
			issues.append(PreflightIssue(
				.localized("Certificate expired"),
				String.localized("The selected certificate expired on %@.", arguments: expiration.formatted(date: .abbreviated, time: .omitted)),
				severity: .blocking
			))
			return
		}

		// Warn within 7 days.
		if expiration.timeIntervalSinceNow < 7 * 24 * 3600 {
			issues.append(PreflightIssue(
				.localized("Certificate expiring soon"),
				String.localized("The selected certificate expires %@.", arguments: RelativeDateTimeFormatter().localizedString(for: expiration, relativeTo: Date()))
			))
		}
	}

	// MARK: Profile compatibility

	/// Compares the selected certificate with the app before the long sign. Nothing compared them
	/// before: an explicit App ID that did not cover the bundle, an entitlement the profile never
	/// granted, an uncovered extension, or a profile issued for a different certificate all
	/// surfaced as an install failure two minutes later (see docs/AUDIT_2026-10-31.md).
	private static func profileCompatibility(
		app: AppInfoPresentable,
		options: Options,
		certificate: CertificatePair?,
		into issues: inout [PreflightIssue]
	) {
		// Modify-only never uses the certificate, and a missing profile is reported by the
		// signing path itself rather than guessed at here.
		guard options.signingOption == .default, let certificate, let profile = certificate.decodedProfile else { return }

		// Extensions the options strip before signing (`removeAppExtensions`) are gone by the
		// time the engine runs, so they are not something the profile has to cover.
		let nested = Storage.shared.getAppDirectory(for: app)
			.map { NestedBundleAudit.requiredIdentifiers(in: $0, removeAppExtensions: options.removeAppExtensions) } ?? []

		let evaluation = ProfileCompatibility.evaluate(
			profile: profile,
			leafCertificateDER: certificate.appliedCertificateDER,
			target: ProfileCompatibility.Target(app: app, options: options, nestedBundleIdentifiers: nested)
		)

		for issue in evaluation.issues {
			issues.append(PreflightIssue(
				title(for: issue.code),
				issue.detail,
				severity: issue.isBlocking ? .blocking : .warning
			))
		}
	}

	private static func title(for code: ProfileCompatibility.Issue.Code) -> String {
		switch code {
		case .profileMissing:
			.localized("No provisioning profile")
		case .profileExpired:
			.localized("Profile expired")
		case .appIdentifierMismatch:
			.localized("Profile does not cover this app")
		case .extensionNotCovered:
			.localized("Extension not covered")
		case .entitlementNotGranted:
			.localized("Entitlement not granted")
		case .teamMismatch:
			.localized("Team mismatch")
		case .certificateNotInProfile:
			.localized("Certificate not in profile")
		case .deviceNotProvisioned:
			.localized("Device not provisioned")
		}
	}

	// MARK: Signer identity

	/// Warns before an app is re-signed with a certificate that is not the one it already
	/// carries.
	///
	/// This is a warning, never a blocker: re-signing with a new identity is a legitimate thing
	/// to want, and iOS will accept the bundle — just not as an update to the copy already on the
	/// device. The message says what that costs, and the alert the user is looking at offers
	/// Cancel.
	private static func signerIdentity(
		app: AppInfoPresentable,
		options: Options,
		certificate: CertificatePair?,
		into issues: inout [PreflightIssue]
	) {
		guard options.signingOption == .default else { return }
		guard let certificate, app.isSigned else { return }
		guard let directory = Storage.shared.getAppDirectory(for: app) else { return }

		let match = CertificateIdentity.match(forBundleAt: directory, certificate: certificate)
		guard case .different(let signer, _) = match, let detail = match.detail else { return }

		issues.append(PreflightIssue(
			.localized("Signed by a different certificate"),
			detail,
			severity: .warning
		))

		// The fingerprint is the only unambiguous identifier when both certificates were issued
		// to the same person — the common case for a re-issued Apple Development certificate.
		SigningLog.shared.warn(
			String.localized(
				"Bundle was signed by %@ (%@); signing with %@.",
				arguments: signer.displayName, signer.shortFingerprint, CertificateIdentity.label(for: certificate)
			)
		)
	}

	// MARK: JIT

	/// JIT needs `get-task-allow`, which only a PPQ (development) profile grants.
	/// Signing continues either way — the entitlement is simply dropped — so this is
	/// a warning, not a blocker.
	private static func jitEntitlement(certificate: CertificatePair?, options: Options, into issues: inout [PreflightIssue]) {
		guard options.enableJIT, options.signingOption == .default else { return }

		guard let certificate else {
			issues.append(PreflightIssue(
				.localized("JIT needs a certificate"),
				.localized("The JIT entitlement is only written when signing with a certificate.")
			))
			return
		}

		guard !certificate.supportsJIT else { return }

		issues.append(PreflightIssue(
			.localized("JIT requires a PPQ certificate"),
			.localized("The selected certificate uses a PPQLess distribution profile, so the JIT entitlement will be dropped. Pick a PPQ certificate or turn JIT off.")
		))
	}

	// MARK: Dylib injections

	private static func dylibInjections(app: AppInfoPresentable, options: Options, into issues: inout [PreflightIssue]) {
		var names: [String: Int] = [:]

		for file in options.injectionFiles {
			_register(file.lastPathComponent, in: &names)
			_architectureCheck(file, app: app, into: &issues)
		}
		for spec in options.tweakInjections ?? [] where spec.enabled {
			for file in spec.files where file.enabled {
				_register(file.fileName, in: &names)
				_architectureCheck(file.fileURL, app: app, into: &issues)
			}
		}

		for (name, count) in names where count > 1 {
			issues.append(PreflightIssue(
				.localized("Duplicate dylib"),
				String.localized("“%@” is injected %lld times. Duplicate injections can make the sign fail.", arguments: name, count)
			))
		}
	}

	private static func _register(_ name: String, in names: inout [String: Int]) {
		names[name, default: 0] += 1
	}

	private static func _architectureCheck(_ file: URL, app: AppInfoPresentable, into issues: inout [PreflightIssue]) {
		// Match the injected Mach-O against the app's own arm64 slice; a mixed-architecture dylib
		// is a silent blank launch otherwise.
		guard
			let appDir = Storage.shared.getAppDirectory(for: app),
			let plist = NSDictionary(contentsOf: appDir.appendingPathComponent("Info.plist")),
			let executableName = plist["CFBundleExecutable"] as? String,
			!executableName.isEmpty
		else {
			return
		}

		let appBinary = appDir.appendingPathComponent(executableName)
		guard FileManager.default.fileExists(atPath: appBinary.path) else { return }

		let arch = dylibArchitecture(at: file)
		let appArches = appArchitectures(at: appBinary)

		guard let arch, let appArches, !appArches.isEmpty else { return }
		guard appArches.contains(arch) else {
			issues.append(PreflightIssue(
				.localized("Architecture mismatch"),
				String.localized("“%@” is not built for the app's architecture and may fail to load.", arguments: file.lastPathComponent),
				severity: .warning
			))
			return
		}
	}

	private static func dylibArchitecture(at url: URL) -> String? {
		guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count >= 4 else { return nil }
		let slice = MachOReader.sliceOffset(in: data)
		guard let cputype = MachOReader.u32(data, at: slice + 4, bigEndian: false) else { return nil }
		return String(format: "0x%08x", cputype)
	}

	private static func appArchitectures(at url: URL) -> [String]? {
		guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
		guard let magic = MachOReader.u32(data, at: 0, bigEndian: true) else { return nil }
		switch magic {
		case MachOReader.fat, MachOReader.fat64:
			// Enumerate fat slices.
			let entrySize = magic == MachOReader.fat ? 20 : 32
			guard let nfat = MachOReader.u32(data, at: 4, bigEndian: true) else { return nil }
			var arches: [String] = []
			for i in 0..<Int(nfat) {
				let entry = 8 + i * entrySize
				if let cpu = MachOReader.u32(data, at: entry, bigEndian: true) {
					arches.append(String(format: "0x%08x", cpu))
				}
			}
			return arches
		default:
			guard let cpu = MachOReader.u32(data, at: 4, bigEndian: false) else { return nil }
			return [String(format: "0x%08x", cpu)]
		}
	}
}
