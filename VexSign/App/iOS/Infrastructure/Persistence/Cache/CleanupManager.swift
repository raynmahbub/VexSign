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
import CoreData
import OSLog
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
    /// Stable identifiers for commit-aware callers; never persisted or shown to the user.
    var removedAppIDs: [String] = []
	var categories: [StorageCategory] = []
	var freedBytes: Int64 = 0
	/// Areas that were asked for and left alone because an operation was still running.
	var deferred: [StorageCategory] = []

	/// Nothing was deleted; used to skip the toast and the "last run" bookkeeping.
	var isIdle: Bool { removedApps.isEmpty && categories.isEmpty }

	/// One sentence naming what was left for later, or nil when nothing was. For whoever asked
	/// for the cleanup: without it, "nothing to clean up" is all they would be told.
	var deferralNotice: String? {
		guard !deferred.isEmpty else { return nil }
		let names = ListFormatter.localizedString(byJoining: deferred.map(\.title))
		return String.localized("Not cleaned while an operation is running: %@", arguments: names)
	}

	mutating func absorb(_ other: CleanupSummary) {
		removedApps += other.removedApps
        removedAppIDs += other.removedAppIDs
		categories += other.categories
		freedBytes += other.freedBytes
		deferred += other.deferred.filter { !deferred.contains($0) }
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
            // The master switch cancels staged auto-deletion requests. Re-enabling cleanup later
            // must not delete apps from installs that finished while cleanup was disabled.
			_pending = []
			return
		}

		let uuids = _pending
		var summary = CleanupSummary()

		if !uuids.isEmpty {
            if _defaults.bool(forKey: Key.deleteAfterInstall) {
                do {
                    let lookup = try _fetchPendingInstallApps(Set(uuids))
                    let deletion = delete(lookup.apps)
                    summary.absorb(deletion)
                    // Existing rows stay pending until their deletion transaction commits.
                    // A successful committed-store lookup that finds no row is already satisfied;
                    // lookup errors retain every UUID and must never be mistaken for an empty library.
                    _pending = PendingInstallCleanupPolicy.remaining(
                        uuids, afterDeleting: Set(deletion.removedAppIDs), confirmedMissing: lookup.confirmedMissing
                    )
                } catch {
                    Logger.misc.error("Install cleanup target lookup failed; pending UUIDs retained.")
                    _pending = PendingInstallCleanupPolicy.remaining(uuids, afterDeleting: [])
                }
            } else {
                // Preserve the shipped setting semantics: turning off delete-after-install
                // cancels staged requests rather than applying them if the toggle is enabled later.
                _pending = []
            }
        }

		summary.absorb(purgeEnabledCategories())
		report(summary, trigger: .install, silent: silent)
	}

    private func _fetchPendingInstallApps(_ uuids: Set<String>) throws -> (apps: [AppInfoPresentable], confirmedMissing: Set<String>) {
        StorageConcurrency.requireMainQueue()
        guard !uuids.isEmpty else { return ([], []) }
        let identifiers = Array(uuids)
        let storage = Storage.shared
        let committedReader = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        committedReader.persistentStoreCoordinator = storage.container.persistentStoreCoordinator

        let committedSignedRequest: NSFetchRequest<Signed> = Signed.fetchRequest()
        committedSignedRequest.predicate = NSPredicate(format: "uuid IN %@", identifiers)
        committedSignedRequest.includesPendingChanges = false
        let committedImportedRequest: NSFetchRequest<Imported> = Imported.fetchRequest()
        committedImportedRequest.predicate = NSPredicate(format: "uuid IN %@", identifiers)
        committedImportedRequest.includesPendingChanges = false
        let committedSigned = try committedReader.fetch(committedSignedRequest).compactMap(\.uuid)
        let committedImported = try committedReader.fetch(committedImportedRequest).compactMap(\.uuid)
        let committedIDs = Set(committedSigned + committedImported)

        // Resolve only committed identities into the view context that owns rows passed to
        // deleteApps. Pending view inserts must not turn an absent committed row into an install
        // cleanup target; pending deletions must not make a still-committed row look absent.
        let viewContext = storage.context
        let viewSignedRequest: NSFetchRequest<Signed> = Signed.fetchRequest()
        viewSignedRequest.predicate = NSPredicate(format: "uuid IN %@", identifiers)
        let viewImportedRequest: NSFetchRequest<Imported> = Imported.fetchRequest()
        viewImportedRequest.predicate = NSPredicate(format: "uuid IN %@", identifiers)
        let viewSigned = try viewContext.fetch(viewSignedRequest)
        let viewImported = try viewContext.fetch(viewImportedRequest)
        let pendingInsertIDs = Set((viewSigned.filter { $0.isInserted && !$0.isDeleted }.compactMap(\.uuid)) +
            (viewImported.filter { $0.isInserted && !$0.isDeleted }.compactMap(\.uuid)))
        let apps = (viewSigned.filter { committedIDs.contains($0.uuid ?? "") } +
            viewImported.filter { committedIDs.contains($0.uuid ?? "") }).map { $0 as AppInfoPresentable }
        let missing = uuids.subtracting(committedIDs).subtracting(pendingInsertIDs)
        return (apps, missing)
    }

	// MARK: - Signing

	/// Runs when a sign has succeeded: settles the two copies, then sweeps the storage toggles.
	///
	/// The signed copy is never deleted here, whatever the settings. The only copy this can
	/// remove is the one the run was started from, and only once the signed copy is confirmed to
	/// be in the library with its bundle on disk. `PostSignArtifacts` holds the rule; this
	/// carries it out.
	///
	/// - Parameters:
	///   - source: the copy the run was started from.
	///   - output: the copy the run produced.
	///   - origin: the flow that ran the sign.
	///   - runDeletesSource: the run's own "Delete After Signing" option.
	///   - sweepsStorage: `false` when the caller sweeps once for several runs, or never did.
	@discardableResult
	func finishSign(
		source: AppInfoPresentable,
		output: AppInfoPresentable,
		origin: PostSignArtifacts.Origin,
		runDeletesSource: Bool = false,
		sweepsStorage: Bool = true
	) -> PostSignArtifacts.Outcome {
		let run = PostSignArtifacts.Run(
			origin: origin,
			sourceID: source.uuid,
			sourceIsSigned: source.isSigned,
			outputID: output.uuid,
			runDeletesSource: runDeletesSource
		)

		var summary = CleanupSummary()
		let outcome = PostSignArtifacts.finish(
			run,
			settings: .stored(in: _defaults),
			outputIsInLibrary: { _holdsSignedCopy($0) },
			removeSource: { cause in
				let removed = delete([source])
				guard !removed.removedApps.isEmpty else { return false }
				// Only what an Auto Cleanup switch removed is reported as a cleanup. A flow using
				// up its own import, or a run's own option, stays as quiet as it was.
				if cause == .cleanupSetting { summary.absorb(removed) }
				return true
			}
		)

		guard sweepsStorage, isEnabled else {
			// Nothing is swept for this caller. What an Auto Cleanup switch removed still goes
			// into the history, without a toast: a batch has always removed its sources quietly.
			report(summary, trigger: .sign, silent: true)
			return outcome
		}

		summary.absorb(purgeEnabledCategories())
		report(summary, trigger: .sign, silent: false)
		return outcome
	}

	/// The storage sweep on its own, for a caller that settled several runs first.
	func sweepAfterSigning() {
		guard isEnabled else { return }
		report(purgeEnabledCategories(), trigger: .sign, silent: false)
	}

	/// True when the library has a signed row for `uuid` and that row's bundle is on disk.
	private func _holdsSignedCopy(_ uuid: String) -> Bool {
		guard let row = Storage.shared.getAllApps().first(where: { $0.isSigned && $0.uuid == uuid }) else {
			return false
		}
		return Storage.shared.getAppDirectory(for: row) != nil
	}

	// MARK: - Downloads

	/// Removes a downloaded IPA (and its staging copy) once it has been imported.
	func purgeDownloadArtifacts(fileURL: URL?, stageURL: URL?) {
		guard isEnabled, _defaults.bool(forKey: Key.deleteDownloadedIPA) else { return }

		var freed: Int64 = 0
		var removed = false
        var visited = Set<String>()
        let stagingRoot = _fileManager.downloadStaging
        let temporaryRoot = _fileManager.temporaryDirectory
        let protectedRoots = _downloadArtifactProtectedRoots

		for url in [fileURL, stageURL].compactMap({ $0 }) {
            let path = url.standardizedFileURL.path
            guard visited.insert(path).inserted,
                  CleanupArtifactPolicy.isSafeDownloadedArtifact(
                    url, stagingRoot: stagingRoot, temporaryRoot: temporaryRoot,
                    protectedRoots: protectedRoots, fileManager: _fileManager
                  ) else { continue }
            let size = _fileManager.allocatedSize(at: url)
            do {
                try _fileManager.removeItem(at: url)
                freed += size
                removed = true
            } catch {
                Logger.misc.warning("Downloaded artifact cleanup failed: \(LogRedaction.redact(error.localizedDescription), privacy: .public)")
            }
		}

		guard removed else { return }
		var summary = CleanupSummary()
		summary.freedBytes = freed
		summary.categories = []
		// A download isn't an app, so the toast only reports the space.
		report(summary, trigger: .sign, silent: true, force: true)
	}

    private var _downloadArtifactProtectedRoots: [URL] {
        var roots = [
            URL.documentsDirectory,
            _fileManager.signed, _fileManager.unsigned, _fileManager.archives,
            _fileManager.tweaksLibrary, _fileManager.entitlementsLibrary,
            _fileManager.webManagerInbox, _fileManager.firmware
        ]
        roots += _fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        roots += _fileManager.urls(for: .libraryDirectory, in: .userDomainMask)
        return roots
    }

	// MARK: - Manual

	/// "Clean Now": everything the user asked for, plus temporary files when the master switch is
	/// off and they only want a one-off sweep.
	///
	/// It is not only the button: Shortcuts, the web API, the companion and the background
	/// automation call it too, at moments nobody chose. So it defers the same areas an automatic
	/// pass defers while an operation is running, and says which ones in `deferred`.
	@discardableResult
	func cleanNow() -> CleanupSummary {
		var summary = CleanupSummary()

		var categories = enabledCategories
		if categories.isEmpty {
			categories = [.caches, .temporary, .leftovers]
		}
		summary.absorb(purgeWhatMayBeCleared(of: categories))

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
		guard !apps.isEmpty else { return CleanupSummary() }

		let living = Storage.shared.getAllApps()
		let targets = apps.compactMap { app -> AppInfoPresentable? in
			guard let uuid = app.uuid else { return nil }
			return living.first { $0.uuid == uuid }
		}
		guard !targets.isEmpty else { return CleanupSummary() }

        // App rows are reported only after the transaction commits; bytes are counted per
        // quarantine item only when its staged directory was actually removed.
        let deletion = Storage.shared.deleteAppsWithOutcome(targets)
        guard deletion.committed else { return CleanupSummary() }
        return CleanupSummary(
            removedApps: targets.map { $0.name ?? .localized("App") },
            removedAppIDs: targets.compactMap(\.uuid),
            categories: [],
            freedBytes: deletion.freedBytes,
            deferred: []
        )
	}

	private func purgeEnabledCategories() -> CleanupSummary {
		purgeWhatMayBeCleared(of: enabledCategories)
	}

	/// Clears `categories`, except the areas a running operation still needs: see
	/// `CleanupPassPolicy`. What is left alone is recorded in the summary's `deferred`.
	private func purgeWhatMayBeCleared(of categories: [StorageCategory]) -> CleanupSummary {
        let guarded = categories.filter { $0 == .temporary || $0 == .leftovers }
        let lease = guarded.isEmpty ? nil : AppOperationRegistry.shared.acquireCleanup()
        defer { withExtendedLifetime(lease) {} }
        let plan = CleanupPassPolicy.plan(categories, operationsActive: lease == nil)
        var summary = CleanupSummary()
        summary.deferred = plan.deferred
        for category in plan.clear {
            let freed = StorageManager.shared.purge(category, cleanupLease: lease)
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

// MARK: - Stored switches
extension PostSignArtifacts.Settings {
	/// The Auto Cleanup switches as the user has them now.
	static func stored(in defaults: UserDefaults = .standard) -> PostSignArtifacts.Settings {
		PostSignArtifacts.Settings(
			autoCleanup: defaults.bool(forKey: CleanupManager.Key.enabled),
			deleteUnsignedSource: defaults.bool(forKey: CleanupManager.Key.deleteSourceAfterSign),
			deleteSignedSource: defaults.bool(forKey: CleanupManager.Key.deleteSignedAfterSign)
		)
	}
}
