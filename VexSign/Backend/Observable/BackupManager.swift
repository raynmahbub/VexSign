//
//  BackupManager.swift
//  VexSign
//
//  Created by VexSign Team
//

import Foundation
import CryptoKit
import Zip
import NimbleExtensions

/// What a backup archive may contain.
///
/// There is deliberately no task-history component. The Activity log is a JSON journal that marks
/// itself `isExcludedFromBackup`, so the app already treats it as data that must not travel, and it
/// records what *this* install did on *this* device — restoring it elsewhere would report work that
/// install never performed. A backup therefore carries what a user configured and produced
/// (certificates, sources, settings, tweaks, signed and imported apps), not what they did.
struct BackupComponents: OptionSet, Hashable, Codable {
	let rawValue: Int

	static let certificates = BackupComponents(rawValue: 1 << 0)
	static let sources = BackupComponents(rawValue: 1 << 1)
	static let settings = BackupComponents(rawValue: 1 << 2)
	static let tweaks = BackupComponents(rawValue: 1 << 3)
    static let library = BackupComponents(rawValue: 1 << 4)

	static let ordered: [BackupComponents] = [.certificates, .sources, .settings, .tweaks, .library]

	init(rawValue: Int) { self.rawValue = rawValue }

	init(from decoder: Decoder) throws {
		rawValue = try decoder.singleValueContainer().decode(Int.self)
	}

	func encode(to encoder: Encoder) throws {
		var container = encoder.singleValueContainer()
		try container.encode(rawValue)
	}

	var title: String {
		switch self {
		case .certificates: .localized("Certificates")
		case .sources: .localized("Sources")
		case .settings: .localized("Settings")
		case .tweaks: .localized("Tweaks")
        case .library: .localized("App Library")
		default: ""
		}
	}

	var icon: String {
		switch self {
		case .certificates: "checkmark.seal"
		case .sources: "globe.desk"
		case .settings: "gear"
		case .tweaks: "wrench.and.screwdriver"
        case .library: "square.stack.3d.up"
		default: "questionmark"
		}
	}
}

struct BackupManifest: Codable {
	var version: Int
	var createdAt: Date
	var appVersion: String
	var contents: BackupComponents?
	var includesTweaks: Bool?
	var counts: [String: Int]?
	var selectedCertUUID: String?
	var certificates: [Cert]
	var sources: [Source]
    var apps: [LibraryBackupEntry]? = nil

	struct Cert: Codable {
		var uuid: String
		var nickname: String?
		var password: String?
		var expiration: Date
		var ppq: Bool
	}

	struct Source: Codable {
		var identifier: String
		var name: String?
		var url: URL
		var iconURL: URL?
	}

	var storedContents: BackupComponents {
		if let contents { return contents }
		var inferred: BackupComponents = [.settings]
		if !certificates.isEmpty { inferred.insert(.certificates) }
		if !sources.isEmpty { inferred.insert(.sources) }
		if includesTweaks == true { inferred.insert(.tweaks) }
		return inferred
	}

    /// Reject unknown schemas/components rather than silently performing a partial migration.
    /// Versions 1–2 infer their legacy settings/source/certificate selection; library needs v3.
    func validateSupportedFormat() throws {
        let supported = BackupComponents.ordered.reduce(0) { $0 | $1.rawValue }
        guard (1...3).contains(version), storedContents.rawValue >= 0,
              storedContents.rawValue & ~supported == 0,
              counts?.values.allSatisfy({ $0 >= 0 }) ?? true,
              Set(certificates.map(\.uuid)).count == certificates.count,
              Set(sources.map(\.identifier)).count == sources.count else { throw BackupCrypto.Failure.badFormat }
        if storedContents.contains(.library) {
            guard version == 3, let apps, !apps.isEmpty,
                  Set(apps.map(\.uuid)).count == apps.count else { throw BackupCrypto.Failure.badFormat }
            for entry in apps { try LibraryBackupSupport.validate(entry) }
        }
        // An archive is a file the user may have been given, not one this app wrote for
        // itself. Its certificate identifiers become directory names under the app's own
        // container (`certs/<uuid>` and the destination `Certificates/<uuid>`), so a manifest
        // may name only identifiers — never a path. `Set(\.uuid).count` above only requires
        // them to be distinct.
        guard certificates.allSatisfy({ UUID(uuidString: $0.uuid) != nil }) else {
            throw BackupCrypto.Failure.badFormat
        }
        // Restore passes `enforceTransportPolicy: false` so a saved LAN repository keeps
        // working; that exemption is about HTTPS, not about what a URL is.
        for source in sources {
            try SourceURLPolicy.validateRestorable(source.url)
            if let iconURL = source.iconURL { try SourceURLPolicy.validateRestorable(iconURL) }
        }
    }

	func count(of component: BackupComponents) -> Int? {
		switch component {
		case .certificates: certificates.count
		case .sources: sources.count
        case .library: apps?.count ?? 0
		default: counts?[String(component.rawValue)]
		}
	}
}

/// What was actually inside the container, checked after authenticated
/// decryption and before anything is written back.
struct BackupIntegrity {
	/// SHA-256 of the decrypted archive, so two backups of the same content can be
	/// told apart from two that merely look alike.
	let packSHA256: String
	let certificateEntries: Int
	let certificateDirectories: Int

	var isComplete: Bool { certificateDirectories == certificateEntries }

	var summary: String {
		let hash = packSHA256.isEmpty ? String.localized("unavailable") : String(packSHA256.prefix(12))
		if certificateEntries == 0 {
			return String.localized("Integrity: no certificates · SHA-256 %@", arguments: hash)
		}
		return String.localized(
			"Integrity: %lld of %lld certificate folders present · SHA-256 %@",
			arguments: Int64(certificateDirectories), Int64(certificateEntries), hash
		)
	}
}

final class BackupArchive: Identifiable {
	let id = UUID()
	let manifest: BackupManifest
	let integrity: BackupIntegrity
	fileprivate let root: URL
	private let _work: URL
    private let _workLease: AppOperationRegistry.Lease

	fileprivate init(manifest: BackupManifest, root: URL, work: URL, integrity: BackupIntegrity, workLease: AppOperationRegistry.Lease) {
		self.manifest = manifest
		self.root = root
		self._work = work
        self._workLease = workLease
		self.integrity = integrity
	}

	deinit {
		try? FileManager.default.removeItem(at: _work)
	}

	var contents: BackupComponents { manifest.storedContents }
}

struct BackupRestoreTally {
	private(set) var added = 0
	private(set) var skipped = 0

	mutating func recordAttempt(error: Error?) {
		if error == nil { added += 1 } else { skipped += 1 }
	}

	mutating func recordSkipped() {
		skipped += 1
	}
}

struct BackupRestoreSummary {
	private(set) var restored: BackupComponents = []
	private var _added: [BackupComponents: Int] = [:]
	private var _skipped: [BackupComponents: Int] = [:]

	mutating func record(_ component: BackupComponents, added: Int, skipped: Int) {
		restored.insert(component)
		_added[component] = added
		_skipped[component] = max(0, skipped)
	}

	var lines: [String] {
		BackupComponents.ordered.compactMap { component in
			guard restored.contains(component) else { return nil }
			let added = _added[component] ?? 0
			let skipped = _skipped[component] ?? 0
			return skipped > 0
			? .localized("%@: %lld added, %lld skipped", arguments: component.title, added, skipped)
			: .localized("%@: %lld added", arguments: component.title, added)
		}
	}
}

@MainActor
final class BackupManager {
	static let shared = BackupManager()
	private let _fm = FileManager.default

	enum Failure: LocalizedError {
		case empty

		var errorDescription: String? {
			String.localized("Nothing to back up.")
		}
	}

	/// Backs up any key in the app's namespaces; device/install-specific and credential keys are
	/// excluded.
	private static let _settingPrefixes = ["VexSign.", "vexsign.", "VexSign.", "signing_options"]
	private static let _settingDenylist: Set<String> = [
		"vexsign.selectedCert",              // restored by uuid remap, not by raw index
		"VexSign.premiumSourceHosts",       // premium activation is install-bound
		"VexSign.defaultImportFolderName",
		"VexSign.defaultImportFolderBookmark", // security-scoped, dead on another install
		"VexSign.downloadBubblePositionX",
		"VexSign.downloadBubblePositionY",
		// Written by builds that kept the cloud-signing bearer token in preferences. It lives in
		// the Keychain now, but an older backup may still carry the plaintext copy. Both spellings
		// are listed because both prefixes are accepted and the deny list is exact.
		"VexSign.cloudSigningKey",
		"vexsign.cloudSigningKey"
	]

	/// Namespaces that hold secrets, never settings a backup should carry.
	private static let _credentialPrefixes = ["VexSign.vault.", "vexsign.vault."]
	/// Credential-shaped names inside an otherwise ordinary namespace.
	private static let _credentialSuffixes = [".apikey", ".token", ".secret", ".password", ".passphrase"]

	/// Whether a preferences key is a credential.
	///
	/// A backup carries its settings in a password-protected container, but a restore also writes
	/// them straight into `UserDefaults` — and a container is only as private as where the user
	/// puts it. Secrets belong to the Keychain, per install, and are never restored from a file.
	static func isCredentialSettingKey(_ key: String) -> Bool {
		let lowered = key.lowercased()
		if _credentialPrefixes.contains(where: { lowered.hasPrefix($0.lowercased()) }) { return true }
		return _credentialSuffixes.contains(where: { lowered.hasSuffix($0) })
	}

	static func isBackupableSettingKey(_ key: String) -> Bool {
		guard _settingPrefixes.contains(where: { key.hasPrefix($0) }) else { return false }
		if _settingDenylist.contains(key) { return false }
		if key.hasPrefix("VexSign.certHash.") { return false }
		if isCredentialSettingKey(key) { return false }
		return true
	}

	func availableComponents() -> (components: BackupComponents, counts: [BackupComponents: Int]) {
		let counts: [BackupComponents: Int] = [
            .library: Storage.shared.getAllApps().count,
            .certificates: Storage.shared.getAllCertificates().count,
			.sources: Storage.shared.getSources().count,
			.tweaks: TweakManager.shared.tweaks.count,
			.settings: UserDefaults.standard.dictionaryRepresentation().keys.filter(Self.isBackupableSettingKey).count
		]
		var components: BackupComponents = []
		for (component, count) in counts where count > 0 { components.insert(component) }
		return (components, counts)
	}

	func makeBackup(password: String, components: BackupComponents) async throws -> URL {
        let workLease = try await AppOperationRegistry.shared.acquireTemporaryWork()
        defer { withExtendedLifetime(workLease) {} }
		// A backup with certificates carries private keys and their passwords, so
		// it never leaves this app without a password of the user's choosing.
		let trimmedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
		if components.contains(.certificates), trimmedPassword.count < BackupCrypto.minimumPasswordLength {
			throw BackupCrypto.Failure.certificatesNeedPassword
		}

		let staging = _fm.uniqueTemporaryDirectory("VexBackup")
		try _fm.createDirectory(at: staging, withIntermediateDirectories: true)
		defer { try? _fm.removeItem(at: staging) }

        if components.contains(.library) { try requireIdleLibrary() }
        var written: BackupComponents = []
		var counts: [String: Int] = [:]
		var certEntries: [BackupManifest.Cert] = []
		var sources: [BackupManifest.Source] = []
		var selectedUUID: String?

		if components.contains(.certificates) {
			let certs = Storage.shared.getAllCertificates()
			let certsDir = staging.appendingPathComponent("certs")
			for cert in certs {
				guard
					let uuid = cert.uuid,
					let p12 = Storage.shared.getFile(.certificate, from: cert),
					let provision = Storage.shared.getFile(.provision, from: cert)
				else { continue }

				let dst = certsDir.appendingPathComponent(uuid)
				try _fm.createDirectory(at: dst, withIntermediateDirectories: true)
				try _fm.copyItem(at: p12, to: dst.appendingPathComponent("certificate.p12"))
				try _fm.copyItem(at: provision, to: dst.appendingPathComponent("certificate.mobileprovision"))
				certEntries.append(.init(
					uuid: uuid,
					nickname: cert.nickname,
					password: cert.signingPassword,
					expiration: cert.expiration ?? Date(),
					ppq: cert.ppQCheck
				))
			}

			let selectedIndex = UserDefaults.standard.integer(forKey: "vexsign.selectedCert")
			selectedUUID = (selectedIndex >= 0 && selectedIndex < certs.count) ? certs[selectedIndex].uuid : nil
			if !certEntries.isEmpty { written.insert(.certificates) }
		}

		if components.contains(.sources) {
			sources = Storage.shared.getSources().compactMap { source in
				guard let url = source.sourceURL, let identifier = source.identifier else { return nil }
				guard !VexSignAPI.isPremiumSource(url) else { return nil }
				return .init(identifier: identifier, name: source.name, url: url, iconURL: source.iconURL)
			}
			if !sources.isEmpty { written.insert(.sources) }
		}

		if components.contains(.settings) {
			var settings: [String: Any] = [:]
			for (key, value) in UserDefaults.standard.dictionaryRepresentation() where Self.isBackupableSettingKey(key) {
				settings[key] = value
			}
			if !settings.isEmpty {
				let data = try PropertyListSerialization.data(fromPropertyList: settings, format: .binary, options: 0)
				try data.write(to: staging.appendingPathComponent("settings.plist"))
				counts[String(BackupComponents.settings.rawValue)] = settings.count
				written.insert(.settings)
			}
		}

		if components.contains(.tweaks), _fm.fileExists(atPath: _fm.tweaksLibrary.path) {
			try _fm.copyItem(at: _fm.tweaksLibrary, to: staging.appendingPathComponent("tweaks"))
			counts[String(BackupComponents.tweaks.rawValue)] = TweakManager.shared.tweaks.count
			written.insert(.tweaks)
		}

        var libraryEntries: [LibraryBackupEntry] = []
        if components.contains(.library) {
            // Snapshot managed-object metadata on the main actor; only URLs/value records
            // cross into the file-copy worker. A missing app fails the backup, never skips it.
            let snapshots = try Storage.shared.getAllApps().map { app -> (LibraryBackupEntry, URL) in
                guard let uuid = app.uuid, let bundle = Storage.shared.getAppDirectory(for: app) else {
                    throw LibraryBackupSupport.Failure.invalidEntry
                }
                let entry = LibraryBackupEntry(uuid: uuid, bundleName: bundle.lastPathComponent,
                    signed: app.isSigned, name: app.name, identifier: app.identifier,
                    originalIdentifier: app.originalIdentifier, version: app.version,
                    appDescription: app.appDescription, certificateUUID: (app as? Signed)?.certificate?.uuid)
                try LibraryBackupSupport.validate(entry)
                return (entry, bundle)
            }
            libraryEntries = try await Task.detached(priority: .utility) {
                var total: Int64 = 0
                for (entry, bundle) in snapshots {
                    let bytes = try LibraryBackupSupport.validateTree(bundle)
                    guard bytes <= LibraryBackupSupport.maximumBytes - total else { throw LibraryBackupSupport.Failure.tooLarge }
                    total += bytes
                    let destination = staging.appendingPathComponent("library").appendingPathComponent(entry.uuid)
                    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: bundle, to: destination.appendingPathComponent(entry.bundleName))
                }
                _ = try LibraryBackupSupport.validateTree(staging)
                return snapshots.map { $0.0 }
            }.value
            if !libraryEntries.isEmpty { written.insert(.library) }
        }

		guard !written.isEmpty else { throw Failure.empty }

		var manifest = BackupManifest(
			version: 3,
			createdAt: Date(),
			appVersion: Bundle.main.version,
			contents: written,
			includesTweaks: written.contains(.tweaks),
			counts: counts,
			selectedCertUUID: selectedUUID,
			certificates: certEntries,
			sources: sources
		)
        manifest.apps = libraryEntries.isEmpty ? nil : libraryEntries
        let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted]
        let manifestData = try encoder.encode(manifest)
        guard manifestData.count <= LibraryBackupSupport.maximumManifestBytes else { throw BackupCrypto.Failure.badFormat }
        try manifestData.write(to: staging.appendingPathComponent("manifest.json"))
        if components.contains(.library) {
            _ = try await Task.detached { try LibraryBackupSupport.validateTree(staging) }.value
        }

		let packDir = _fm.uniqueTemporaryDirectory("VexBackupPack")
		try _fm.createDirectory(at: packDir, withIntermediateDirectories: true)
		defer { try? _fm.removeItem(at: packDir) }
		let packURL = packDir.appendingPathComponent("pack.zip")

		let outDir = _fm.uniqueTemporaryDirectory("VexBackupOut")
        try _fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        let file = outDir.appendingPathComponent("VexSign-Backup-\(Self._stamp()).vexbackup")
        do {
            let worker = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                try Zip.zipFiles(paths: [staging], zipFilePath: packURL, password: nil, progress: nil)
                // Never emit a container our own safety policy would refuse to restore.
                try ArchiveSafetyValidator.validate(packURL)
                try Task.checkCancellation()
                try BackupCrypto.sealFile(packURL, to: file, password: password)
            }
            try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: { worker.cancel() }
        } catch {
            do { try _fm.removeItem(at: outDir) }
            catch { FileLogger.log("Could not clean failed backup output: \(error)", category: "backup") }
            throw error
        }
		return file
	}

	func open(_ url: URL, password: String) async throws -> BackupArchive {
        let workLease = try await AppOperationRegistry.shared.acquireTemporaryWork()
		let work = _fm.uniqueTemporaryDirectory("VexRestore")
		try _fm.createDirectory(at: work, withIntermediateDirectories: true)

		do {
			let extractDir = work.appendingPathComponent("extract")
            let worker = Task.detached(priority: .userInitiated) {
                let packURL = work.appendingPathComponent("pack.zip")
                let hash = try BackupCrypto.unsealFile(url, to: packURL, password: password)
                try Task.checkCancellation()
                try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
                try ArchiveSafetyValidator.validate(packURL)
                try Zip.unzipFile(packURL, destination: extractDir, overwrite: true, password: nil)
                try Task.checkCancellation()
                return hash
            }
            let packHash = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: { worker.cancel() }

			guard let root = _findRoot(in: extractDir) else { throw BackupCrypto.Failure.badFormat }
            let manifestURL = root.appendingPathComponent("manifest.json")
            guard let metadataSize = try manifestURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  metadataSize <= LibraryBackupSupport.maximumManifestBytes else { throw BackupCrypto.Failure.badFormat }
			let manifestData = try Data(contentsOf: manifestURL)
			let manifest = try JSONDecoder().decode(BackupManifest.self, from: manifestData)

            try manifest.validateSupportedFormat()
            if manifest.storedContents.contains(.library) {
                guard manifest.version >= 3, let apps = manifest.apps, !apps.isEmpty,
                      Set(apps.map(\.uuid)).count == apps.count else { throw BackupCrypto.Failure.badFormat }
                for entry in apps {
                    try LibraryBackupSupport.validate(entry)
                    let bundle = root.appendingPathComponent("library").appendingPathComponent(entry.uuid).appendingPathComponent(entry.bundleName)
                    guard _fm.fileExists(atPath: bundle.appendingPathComponent("Info.plist").path) else {
                        throw LibraryBackupSupport.Failure.invalidEntry
                    }
                }
                _ = try await Task.detached { try LibraryBackupSupport.validateTree(root) }.value
            }

            // Decryption already fails closed; this checks that the container holds
			// what its manifest claims before the user commits to a restore.
			let certRoot = root.appendingPathComponent("certs")
			let present = manifest.certificates.filter {
				_fm.fileExists(atPath: certRoot.appendingPathComponent($0.uuid).path)
			}.count
			let integrity = BackupIntegrity(
				packSHA256: packHash,
				certificateEntries: manifest.certificates.count,
				certificateDirectories: present
			)
			return BackupArchive(manifest: manifest, root: root, work: work, integrity: integrity, workLease: workLease)
		} catch {
			try? _fm.removeItem(at: work)
			throw error
		}
	}

    func restore(_ archive: BackupArchive, components: BackupComponents) async throws -> BackupRestoreSummary {
		let manifest = archive.manifest
		let root = archive.root
		let wanted = components.intersection(archive.contents)
        var summary = BackupRestoreSummary()
        if wanted.contains(.library) { try requireIdleLibrary() }

        if wanted.contains(.certificates) {
			var tally = BackupRestoreTally()
			let existing = Set(Storage.shared.getAllCertificates().compactMap { $0.uuid })
			for cert in manifest.certificates {
				let srcDir = root.appendingPathComponent("certs").appendingPathComponent(cert.uuid)
				let dstDir = _fm.certificates(cert.uuid)
				// An untracked directory can be an interrupted prior import. Never
				// replace it just because the matching Core Data row is absent.
				let plan = BackupRestorePlan.decision(
					alreadyTracked: existing.contains(cert.uuid),
					payloadPresent: _fm.fileExists(atPath: srcDir.path),
					destinationOccupied: _fm.fileExists(atPath: dstDir.path)
				)
				guard plan.shouldRestore else { tally.recordSkipped(); continue }
				do {
					try _fm.copyItem(at: srcDir, to: dstDir)
				} catch {
					tally.recordSkipped()
					continue
				}
				let addError = await withCheckedContinuation { (continuation: CheckedContinuation<Error?, Never>) in
					Storage.shared.addCertificate(
						uuid: cert.uuid,
						password: cert.password,
						nickname: cert.nickname,
						ppq: cert.ppq,
						expiration: cert.expiration,
						completion: { continuation.resume(returning: $0) }
					)
				}
				tally.recordAttempt(error: addError)
				if addError != nil {
					do {
						try _fm.removeItem(at: dstDir)
					} catch {
						FileLogger.log("Could not remove certificate files after a failed backup restore: \(error.localizedDescription)", category: "backup")
					}
				}
			}
			summary.record(.certificates, added: tally.added, skipped: tally.skipped)

			if
				let uuid = manifest.selectedCertUUID,
				let index = Storage.shared.getAllCertificates().firstIndex(where: { $0.uuid == uuid }) {
				UserDefaults.standard.set(index, forKey: "vexsign.selectedCert")
			}
		}

        if wanted.contains(.sources) {
			var tally = BackupRestoreTally()
			for source in manifest.sources {
				if Storage.shared.sourceExists(source.identifier) { tally.recordSkipped(); continue }
				// Restoring the user's own configuration is not a new trust
				// decision: the transport policy is bypassed so a previously
				// saved (e.g. LAN HTTP) repository still restores. Refreshes
				// still respect the SourceURLPolicy until the user opts in.
				let addError = await withCheckedContinuation { (continuation: CheckedContinuation<Error?, Never>) in
					Storage.shared.addSource(
						source.url,
						name: source.name,
						identifier: source.identifier,
						iconURL: source.iconURL,
						enforceTransportPolicy: false,
						completion: { continuation.resume(returning: $0) }
					)
				}
				tally.recordAttempt(error: addError)
			}
			summary.record(.sources, added: tally.added, skipped: tally.skipped)
		}

		if
			wanted.contains(.settings),
			let data = try? Data(contentsOf: root.appendingPathComponent("settings.plist")),
			let dict = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
			var added = 0
			var skipped = 0
			for (key, value) in dict {
				// An archive written by an older build can still hold keys this build no longer
				// considers safe to restore — credentials, or device-specific paths. Report them
				// instead of leaving the count looking complete.
				guard Self.isBackupableSettingKey(key) else { skipped += 1; continue }
				UserDefaults.standard.set(value, forKey: key)
				added += 1
			}
			summary.record(.settings, added: added, skipped: skipped)
		}

		let tweaksDir = root.appendingPathComponent("tweaks")
		if wanted.contains(.tweaks), _fm.fileExists(atPath: tweaksDir.path) {
			let added: Int
            do {
                added = try TweakManager.shared.mergeFromBackup(tweaksDir: tweaksDir)
            } catch {
                // Earlier backup components and the folders manifest may already be committed.
                throw TweakRestorePartialFailure(underlying: error)
            }
			summary.record(.tweaks, added: added, skipped: max(0, (manifest.count(of: .tweaks) ?? added) - added))
		}

        if wanted.contains(.library) {
            var added = 0
            var skipped = 0
            var existing = Set(Storage.shared.getAllApps().compactMap { $0.uuid })
            for entry in manifest.apps ?? [] {
                try requireIdleLibrary()
                try LibraryBackupSupport.validate(entry)
                let source = root.appendingPathComponent("library").appendingPathComponent(entry.uuid).appendingPathComponent(entry.bundleName)
                let destination = entry.signed ? _fm.signed(entry.uuid) : _fm.unsigned(entry.uuid)
                // The same three rules the certificates loop applies, so a damaged entry is
                // skipped here too instead of aborting every entry after it. `open` already
                // checked the bundle exists; this covers a container damaged in between.
                let plan = BackupRestorePlan.decision(
                    alreadyTracked: existing.contains(entry.uuid),
                    payloadPresent: _fm.fileExists(atPath: source.path),
                    destinationOccupied: _fm.fileExists(atPath: destination.path)
                )
                guard plan.shouldRestore else { skipped += 1; continue }
                var copied = false
                do {
                    try await Task.detached(priority: .utility) {
                        _ = try LibraryBackupSupport.validateTree(source)
                        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                        do { try FileManager.default.copyItem(at: source, to: destination.appendingPathComponent(entry.bundleName)) }
                        catch {
                            try FileManager.default.removeItem(at: destination)
                            throw error
                        }
                    }.value
                    copied = true
                    try requireIdleLibrary()
                    guard let bundle = Bundle(url: destination.appendingPathComponent(entry.bundleName)),
                          bundle.bundleIdentifier != nil else { throw LibraryBackupSupport.Failure.invalidEntry }
                    if entry.signed {
                        let certificateID = Storage.shared.getAllCertificates().first { $0.uuid == entry.certificateUUID }?.objectID
                        try await Storage.shared.addSigned(uuid: entry.uuid, certificateID: certificateID,
                            appName: entry.name ?? bundle.name, appIdentifier: bundle.bundleIdentifier,
                            originalAppIdentifier: entry.originalIdentifier, appVersion: bundle.version,
                            appIcon: bundle.iconFileName, appDescription: entry.appDescription)
                    } else {
                        try await Storage.shared.addImported(uuid: entry.uuid, appName: entry.name ?? bundle.name,
                            appIdentifier: bundle.bundleIdentifier, appVersion: bundle.version,
                            appIcon: bundle.iconFileName, appDescription: entry.appDescription)
                    }
                    existing.insert(entry.uuid)
                    added += 1
                } catch {
                    if copied {
                        do { try _fm.removeItem(at: destination) }
                        catch { FileLogger.log("Library restore rollback failed: \(error)", category: "backup") }
                    }
                    // Fail loudly; earlier completed entries remain, and a retry skips them.
                    throw error
                }
            }
            summary.record(.library, added: added, skipped: skipped)
        }

		return summary
	}

    private func requireIdleLibrary() throws {
        guard !SigningService.shared.isSigning, !DownloadManager.shared.hasUnfinishedWork,
              InstallQueue.shared.current == nil else { throw LibraryBackupSupport.Failure.busy }
    }

	private func _findRoot(in dir: URL) -> URL? {
		if _fm.fileExists(atPath: dir.appendingPathComponent("manifest.json").path) { return dir }
		guard let items = try? _fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return nil }
		return items.first { _fm.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) }
	}

	private static func _stamp() -> String {
		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.dateFormat = "yyyyMMdd-HHmm"
		return formatter.string(from: Date())
	}
}

private struct TweakRestorePartialFailure: LocalizedError {
    let underlying: Error
    var errorDescription: String? {
        String.localized("Tweak restore failed: %@. Some earlier backup components or folders may already have been restored.", arguments: underlying.localizedDescription)
    }
}
