//
//  AdditionalProfiles.swift
//  VexSign
//
//  Provisioning profiles for nested bundles.
//
//  A certificate has one main profile, and that profile names one App ID. An app extension
//  with an explicit App ID of its own (com.example.app.widget) is not covered by an explicit
//  main profile, and iOS refuses to install the app. The fix Apple intends is one profile
//  per bundle: the extension is signed with — and carries — a profile issued for it.
//
//  Additional profiles live next to the certificate, in a folder of their own so the
//  certificate's main-profile lookup (first .mobileprovision in the certificate folder) is
//  not affected. They share the certificate's .p12; the engine refuses a profile that was
//  not issued for it.
//

import Foundation
import NimbleExtensions

enum AdditionalProfiles {
	/// Folder inside a certificate's directory. It has no path extension on purpose.
	static let folderName = "ExtensionProfiles"

	struct Entry: Equatable, Identifiable {
		let url: URL
		/// The profile's `application-identifier`, e.g. `TEAMID.com.example.app.widget`.
		let pattern: String
		let name: String
		let expirationDate: Date

		var id: String { url.path }
		var isExpired: Bool { expirationDate < Date() }
	}

	enum ImportProblem: Error, Equatable {
		case unreadable
		case noApplicationIdentifier
		case expired
		case differentTeam
		case duplicate
		case notIssuedForCertificate
		case storageUnavailable

		var message: String {
			switch self {
			case .unreadable:
				.localized("This file could not be read as a provisioning profile.")
			case .noApplicationIdentifier:
				.localized("This profile does not state which app identifier it covers.")
			case .expired:
				.localized("This profile has expired.")
			case .differentTeam:
				.localized("This profile belongs to a different team than the certificate's profile, so it cannot be used with this certificate.")
			case .duplicate:
				.localized("A profile for this app identifier has already been added.")
			case .notIssuedForCertificate:
				.localized("This profile was not issued for this certificate, so the signing engine would refuse it. Add a profile that includes this certificate.")
			case .storageUnavailable:
				.localized("The certificate's folder is unavailable.")
			}
		}
	}

	// MARK: Storage

	static func directory(for certificate: CertificatePair) -> URL? {
		Storage.shared.getUuidDirectory(for: certificate)?.appendingPathComponent(folderName, isDirectory: true)
	}

	static func entries(for certificate: CertificatePair?) -> [Entry] {
		guard let certificate, let directory = directory(for: certificate) else { return [] }
		return entries(in: directory)
	}

	/// Every readable profile in a folder, in a stable order. Unreadable files are skipped:
	/// a profile that cannot be decoded can never be handed to the engine.
	static func entries(in directory: URL, fileManager: FileManager = .default) -> [Entry] {
		let contents: [URL]
		do {
			contents = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
		} catch {
			// The folder is created on first import; its absence means "none added".
			return []
		}
		return contents
			.filter { $0.pathExtension.lowercased() == "mobileprovision" }
			.compactMap(entry(at:))
			.sorted { $0.pattern < $1.pattern }
	}

	static func entry(at url: URL) -> Entry? {
		guard
			let profile = CertificateReader(url).decoded,
			let pattern = profile.Entitlements?["application-identifier"]?.value as? String,
			!pattern.isEmpty
		else { return nil }
		return Entry(url: url, pattern: pattern, name: profile.Name, expirationDate: profile.ExpirationDate)
	}

	/// Why a decoded profile cannot be added to a certificate, or nil when it can.
	static func importProblem(
		pattern: String?,
		expirationDate: Date,
		teamIdentifiers: [String],
		mainTeamIdentifiers: [String],
		existingPatterns: [String],
		profileCertificates: [Data] = [],
		leafCertificate: Data? = nil,
		now: Date = Date()
	) -> ImportProblem? {
		guard let pattern, !pattern.isEmpty else { return .noApplicationIdentifier }
		guard expirationDate >= now else { return .expired }
		if !mainTeamIdentifiers.isEmpty, Set(teamIdentifiers).isDisjoint(with: mainTeamIdentifiers) {
			return .differentTeam
		}
		guard !existingPatterns.contains(pattern) else { return .duplicate }
		// Same rule as `ZsignEngine.identityProblem`: a profile that names certificates must
		// name this one. Unknown on either side is left to the signing-time check.
		if let leafCertificate, !leafCertificate.isEmpty, !profileCertificates.isEmpty {
			let named = profileCertificates.map { SigningIdentity.fingerprint(of: $0) }
			guard named.contains(SigningIdentity.fingerprint(of: leafCertificate)) else { return .notIssuedForCertificate }
		}
		return nil
	}

	/// Copies a profile into the certificate's folder after checking that it can be used.
	@discardableResult
	static func add(from source: URL, to certificate: CertificatePair, fileManager: FileManager = .default) throws -> Entry {
		guard let directory = directory(for: certificate) else { throw ImportProblem.storageUnavailable }
		guard let profile = CertificateReader(source).decoded else { throw ImportProblem.unreadable }

		let pattern = profile.Entitlements?["application-identifier"]?.value as? String
		if let problem = importProblem(
			pattern: pattern,
			expirationDate: profile.ExpirationDate,
			teamIdentifiers: profile.TeamIdentifier,
			mainTeamIdentifiers: certificate.decodedProfile?.TeamIdentifier ?? [],
			existingPatterns: entries(in: directory, fileManager: fileManager).map(\.pattern),
			profileCertificates: profile.DeveloperCertificates ?? [],
			leafCertificate: certificate.appliedCertificateDER
		) {
			throw problem
		}

		try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
		let destination = directory.appendingPathComponent("\(UUID().uuidString).mobileprovision")
		try fileManager.copyItem(at: source, to: destination)
		guard let entry = entry(at: destination) else { throw ImportProblem.unreadable }
		return entry
	}

	static func remove(_ entry: Entry, fileManager: FileManager = .default) throws {
		try fileManager.removeItem(at: entry.url)
	}

	// MARK: Matching

	/// The usable (unexpired) App ID patterns of a certificate's additional profiles.
	static func patterns(for certificate: CertificatePair?) -> [String] {
		entries(for: certificate).filter { !$0.isExpired }.map(\.pattern)
	}

	/// Whether any additional profile covers an identifier.
	static func covers(_ identifier: String, patterns: [String]) -> Bool {
		patterns.contains { SignatureVerifier.coverage(of: $0, includes: identifier) }
	}

	/// Which nested bundle is signed with which additional profile.
	///
	/// - An additional profile whose App ID names the bundle exactly always wins: it was
	///   issued for that bundle.
	/// - Otherwise the main profile is kept whenever it covers the bundle, so adding an
	///   unrelated profile never changes how an already-working app is signed.
	/// - Otherwise the first additional wildcard profile that covers the bundle is used.
	///
	/// A bundle that nothing covers is absent from the result; preflight reports it.
	static func assignments<Value>(
		nestedIdentifiers: [String],
		mainPattern: String?,
		profiles: [(pattern: String, value: Value)]
	) -> [String: Value] {
		var result: [String: Value] = [:]
		for identifier in nestedIdentifiers {
			if let exact = profiles.first(where: { _isExact($0.pattern, for: identifier) }) {
				result[identifier] = exact.value
				continue
			}
			if let mainPattern, SignatureVerifier.coverage(of: mainPattern, includes: identifier) {
				continue
			}
			if let wildcard = profiles.first(where: { SignatureVerifier.coverage(of: $0.pattern, includes: identifier) }) {
				result[identifier] = wildcard.value
			}
		}
		return result
	}

	private static func _isExact(_ pattern: String, for identifier: String) -> Bool {
		!pattern.hasSuffix("*") && SignatureVerifier.coverage(of: pattern, includes: identifier)
	}
}
