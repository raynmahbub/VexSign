//
//  CleanupManager.swift
//  VexSign
//
//  Everything VexSign throws away by itself: the apps that have already been signed or
//  installed, downloaded IPAs, caches, temporary work files, leftovers and exported IPAs.
//
//  One place decides what runs (the toggles in Settings → Auto Cleanup) and one place reports
//  what was freed, so the user never has to walk into Settings and clean up by hand again.
//

import Foundation
import SwiftUI
import NimbleExtensions

// MARK: - Trigger
enum CleanupTrigger {
	/// Signing finished.
	case sign
	/// Installing finished (the install UI is gone).
	case install
	/// The user pressed "Clean Now".
	case manual
	/// Cold launch — pending deletions from a kill mid-install are replayed quietly.
	case launch

	var isAutomatic: Bool { self != .manual }
}

// MARK: - Summary
struct CleanupSummary {
	var removedApps: [String] = []
	var categories: [StorageCategory] = []
	var freedBytes: Int64 = 0

	/// Nothing was deleted; used to skip the toast and the "last run" bookkeeping.
	var isIdle: Bool { removedApps.isEmpty && categories.isEmpty }

	mutating func absorb(_ other: CleanupSummary) {
		removedApps += other.removedApps
		categories += other.categories
		freedBytes += other.freedBytes
	}
}

// MARK: - Manager
@MainActor
final class CleanupManager: ObservableObject {
	static let shared = CleanupManager()

	/// UserDefaults keys. The `VexSign.` ones are shared with the older toggles in
	/// Signing Options / Storage so both screens stay in sync.
	enum Key {
		/// Master switch. Registered as `true` at launch, and every sub-toggle defaults to off,
		/// so upgrading never changes what the app deletes.
		static let enabled = "VexSign.cleanup.enabled"
		/// Import → sign → install → cleanup in one go.
		static let oneTapInstall = "VexSign.cleanup.oneTapInstall"

		static let deleteAfterInstall = "VexSign.deleteAppAfterInstall"
		static let clearCache = "VexSign.clearCacheAfterInstall"

		static let deleteSourceAfterSign = "VexSign.cleanup.deleteSourceAfterSign"
		static let deleteSignedAfterSign = "VexSign.cleanup.deleteSignedAfterSign"
		static let deleteDownloadedIPA = "VexSign.cleanup.deleteDownloadedIPA"
		static let clearTemporary = "VexSign.cleanup.clearTemporary"
		static let removeLeftovers = "VexSign.cleanup.removeLeftovers"
		static let clearArchives = "VexSign.cleanup.clearArchives"

		static let pendingApps = "VexSign.installCleanupPending"
		static let lastRun = "VexSign.cleanup.lastRun"
		static let lastFreed = "VexSign.cleanup.lastFreed"
	}

	private let _defaults = UserDefaults.standard
	private let _fileManager = FileManager.default

	/// Last cleanup that actually removed something, for the settings screen.
	@Published private(set) var lastSummary: CleanupSummary?

	private init() {}

	// MARK: - Settings

	var isEnabled: Bool { _defaults.bool(forKey: Key.enabled) }

	/// True when the user asked for unsigned apps to be dropped as soon as they are signed.
	var deletesSourceAfterSign: Bool { isEnabled && _defaults.bool(forKey: Key.deleteSourceAfterSign) }

	/// Storage areas cleaned after every sign and install.
	var enabledCategories: [StorageCategory] {
		var categories: [StorageCategory] = []
		if _defaults.bool(forKey: Key.clearCache) { categories.append(.caches) }
		if _defaults.bool(forKey: Key.clearTemporary) { categories.append(.temporary) }
		if _defaults.bool(forKey: Key.removeLeftovers) { categories.append(.leftovers) }
		if _defaults.bool(forKey: Key.clearArchives) { categories.append(.archives) }
		return categories
	}

	/// How much the enabled toggles could free right now.
	func reclaimableBytes() -> Int64 {
		StorageManager.shared.reclaimableBytes(enabledCategories)
	}

	var lastRunDate: Date? { _defaults.object(forKey: Key.lastRun) as? Date }

	var lastFreedBytes: Int64 { _defaults.object(forKey: Key.lastFreed) as? Int64 ?? 0 }

	// MARK: - One-tap install

	/// True when every step of the store-like pipeline is on: auto sign → install → cleanup.
	var isOneTapInstall: Bool {
		AutoSignManager.isEnabled
			&& OptionsManager.shared.options.post_installAppAfterSigned
			&& _defaults.bool(forKey: Key.deleteAfterInstall)
			&& _defaults.bool(forKey: Key.clearCache)
	}

	/// Flips the underlying switches. Turning it off leaves the individual toggles alone so the
	/// user keeps whatever they had before.
	func setOneTapInstall(_ isOn: Bool) {
		_defaults.set(isOn, forKey: Key.oneTapInstall)
		guard isOn else { return }

		_defaults.set(true, forKey: AutoSignManager.enabledKey)

		// Auto sign + install after signing live in the signing options.
		OptionsManager.shared.options.post_installAppAfterSigned = true
		OptionsManager.shared.saveOptions()

		// Install finished → drop the app and the caches it left behind.
		_defaults.set(true, forKey: Key.deleteAfterInstall)
		_defaults.set(true, forKey: Key.clearCache)
		objectWillChange.send()
	}

	// MARK: - Staging (install)

	/// Deleting while the card still shows the app would blank it out, so the uuid is parked on
	/// disk first — a kill before the flush still cleans up on the next launch.
	func stage(_ app: AppInfoPresentable) {
		guard let uuid = app.uuid, !_pending.contains(uuid) else { return }
		_pending.append(uuid)
	}

	/// Runs once the install UI is gone.
	func flush(silent: Bool = false) {
		guard isEnabled else {
			_pending = []
			return
		}

		let uuids = _pending
		_pending = []

		var summary = CleanupSummary()

		if !uuids.isEmpty, _defaults.bool(forKey: Key.deleteAfterInstall) {
			let apps = Storage.shared.getAllApps().filter { uuids.contains($0.uuid ?? "") }
			summary.absorb(delete(apps))
		}

		summary.absorb(purgeEnabledCategories())
		report(summary, trigger: .install, silent: silent)
	}

	// MARK: - Signing

	/// Runs when a sign finishes.
	///
	/// - Parameters:
	///   - source: the app that was signed, when the caller did not already delete it.
	///   - signed: the freshly signed copy.
	///   - keepsSignedApp: `true` when install/export needs the signed bundle, or the user
	///     explicitly chose to keep and view it in Library.
	func runAfterSign(
		source: AppInfoPresentable?,
		signed: AppInfoPresentable?,
		keepsSignedApp: Bool
	) {
		guard isEnabled else { return }

		var summary = CleanupSummary()

		if _defaults.bool(forKey: Key.deleteSourceAfterSign), let source, !source.isSigned {
			summary.absorb(delete([source]))
		}

		if _defaults.bool(forKey: Key.deleteSignedAfterSign), !keepsSignedApp, let signed, signed.isSigned {
			summary.absorb(delete([signed]))
		}

		summary.absorb(purgeEnabledCategories())
		report(summary, trigger: .sign, silent: false)
	}

	// MARK: - Downloads

	/// Removes a downloaded IPA (and its staging copy) once it has been imported.
	func purgeDownloadArtifacts(fileURL: URL?, stageURL: URL?) {
		guard isEnabled, _defaults.bool(forKey: Key.deleteDownloadedIPA) else { return }

		var freed: Int64 = 0
		var removed = false

		for url in [fileURL, stageURL].compactMap({ $0 }) {
			// Never delete something outside the sandbox or inside the library itself.
			guard url.path.hasPrefix(URL.documentsDirectory.path) || url.path.hasPrefix(FileManager.default.temporaryDirectory.path) else { continue }
			guard _fileManager.fileExists(atPath: url.path) else { continue }
			freed += _fileManager.allocatedSize(at: url)
			try? _fileManager.removeItem(at: url)
			removed = true
		}

		guard removed else { return }
		var summary = CleanupSummary()
		summary.freedBytes = freed
		summary.categories = []
		// A download isn't an app, so the toast only reports the space.
		report(summary, trigger: .sign, silent: true, force: true)
	}

	// MARK: - Manual

	/// "Clean Now": everything the user asked for, plus temporary files when the master switch is
	/// off and they only want a one-off sweep.
	@discardableResult
	func cleanNow() -> CleanupSummary {
		var summary = CleanupSummary()

		var categories = enabledCategories
		if categories.isEmpty {
			categories = [.caches, .temporary, .leftovers]
		}
		summary.absorb(purge(categories))

		// Optional "keep only the newest signed copy of each app" rule.
		if StorageRules.keepOnlyLatestSigned {
			let pruned = StorageRules.pruneDuplicateSignedApps()
			summary.freedBytes += pruned.freed
			summary.removedApps += pruned.removed
		}

		report(summary, trigger: .manual, silent: false)
		return summary
	}

	// MARK: - Internals

	/// Deletes apps that are still in the library, skipping ones a caller already removed —
	/// touching a deleted CoreData object would fault.
	private func delete(_ apps: [AppInfoPresentable]) -> CleanupSummary {
		var summary = CleanupSummary()
		guard !apps.isEmpty else { return summary }

		let living = Storage.shared.getAllApps()
		let targets = apps.compactMap { app -> AppInfoPresentable? in
			guard let uuid = app.uuid else { return nil }
			return living.first { $0.uuid == uuid }
		}

		guard !targets.isEmpty else { return summary }

		for app in targets {
			if let url = Storage.shared.getUuidDirectory(for: app) {
				summary.freedBytes += _fileManager.allocatedSize(at: url)
			}
			summary.removedApps.append(app.name ?? .localized("App"))
		}

		Storage.shared.deleteApps(targets)
		return summary
	}

	/// The categories an automatic pass may clear right now.
	///
	/// The temporary directory holds the work directory of every sign in flight and the archive
	/// a running install is handing to iOS. Clearing it because one operation finished took
	/// those files away from every other operation still running, which then stopped part-way
	/// with a "no such file" error. While anything is running the directory is left alone; the
	/// next pass that finds nothing running clears it, and so does the next launch.
	nonisolated static func automaticCategories(
		_ enabled: [StorageCategory],
		operationsActive: Bool
	) -> [StorageCategory] {
		operationsActive ? enabled.filter { $0 != .temporary } : enabled
	}

	private func purgeEnabledCategories() -> CleanupSummary {
		purge(Self.automaticCategories(
			enabledCategories,
			operationsActive: AppOperationRegistry.shared.hasActiveOperations
		))
	}

	private func purge(_ categories: [StorageCategory]) -> CleanupSummary {
		var summary = CleanupSummary()
		for category in categories {
			let freed = StorageManager.shared.purge(category)
			guard freed > 0 else { continue }
			summary.freedBytes += freed
			summary.categories.append(category)
		}
		return summary
	}

	private func report(
		_ summary: CleanupSummary,
		trigger: CleanupTrigger,
		silent: Bool,
		force: Bool = false
	) {
		guard !summary.isIdle || force else { return }

		if !summary.isIdle {
			lastSummary = summary
			_defaults.set(Date(), forKey: Key.lastRun)
			_defaults.set(summary.freedBytes, forKey: Key.lastFreed)

			// Keep the invisible tool trustable: a rolling line-item history of what was removed.
			CleanupHistoryStore.shared.record(
				apps: summary.removedApps,
				categories: summary.categories,
				freedBytes: summary.freedBytes
			)
		}

		guard !silent else { return }

		let message = Self.message(for: summary, trigger: trigger)
		Toast.info(message, systemImage: "sparkles", duration: .long)
	}

	/// One line that says what happened, in whatever detail is available.
	private static func message(for summary: CleanupSummary, trigger: CleanupTrigger) -> String {
		let size = summary.freedBytes.formattedFileSize

		if summary.removedApps.isEmpty {
			return String.localized("Cleanup freed %@", arguments: size)
		}

		let names = summary.removedApps.count == 1
			? summary.removedApps[0]
			: String.localized("%lld apps", arguments: summary.removedApps.count)

		if summary.freedBytes > 0 {
			return String.localized("Cleanup removed %@ and freed %@", arguments: names, size)
		}
		return String.localized("Cleanup removed %@", arguments: names)
	}

	// MARK: Pending apps (UserDefaults backed)

	private var _pending: [String] {
		get { _defaults.stringArray(forKey: Key.pendingApps) ?? [] }
		set { _defaults.set(newValue, forKey: Key.pendingApps) }
	}
}
