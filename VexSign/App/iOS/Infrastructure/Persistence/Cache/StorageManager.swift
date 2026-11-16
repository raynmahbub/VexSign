//
//  StorageManager.swift
//  VexSign
//
//  Created by VexSign Team
//

import Foundation
import OSLog
import Nuke
import NimbleExtensions

/// Temporary directories whose consumers may outlive the call that created them.
/// Keep these during a running process; their owners discard them, and launch recovery
/// removes abandoned copies. Matching is at the temporary root, never a substring.
enum TemporaryCleanupPolicy {
    private static let retainedPrefixes = [
        "VexBackupOut_", "VexSignTweak_", "VexSignTweakExtract_",
        "VexSignZipExtract_", "VexSignSharedTweak_", "TweakAnalyze_"
    ]

    static func isRetained(_ url: URL, temporaryRoot: URL, downloadStaging: URL) -> Bool {
        let root = temporaryRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let staging = downloadStaging.resolvingSymlinksInPath().standardizedFileURL.path
        if path == staging || path.hasPrefix(staging + "/") { return true }
        let undoRoot = temporaryRoot.appendingPathComponent("RemovedItems", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL.path
        if path == undoRoot || path.hasPrefix(undoRoot + "/") { return true }
        guard path.hasPrefix(root + "/") else { return false }
        let relative = String(path.dropFirst(root.count + 1))
        guard let first = relative.split(separator: "/").first else { return false }
        return retainedPrefixes.contains { first.hasPrefix($0) }
    }
}

// MARK: - Category
enum StorageCategory: String, CaseIterable, Identifiable {
	case signed
	case imported
	case archives
	case tweaks
	case certificates
	case caches
	case logs
	case temporary
	case leftovers
	case other

	var id: String { rawValue }

	static let safeToClear: [StorageCategory] = [.caches, .logs, .temporary, .leftovers]

	var isBrowsable: Bool {
		switch self {
		case .tweaks, .certificates: false
		default: true
		}
	}

	var allowsExploring: Bool {
		switch self {
		case .signed, .imported, .archives: false
		default: true
		}
	}
}

// MARK: - Report
struct StorageUsage: Identifiable {
	let category: StorageCategory
	let size: Int64
	let count: Int

	var id: String { category.id }

	/// Whether the category holds no items.
	/// Defined because SwiftLint's `empty_count` autocorrect rewrites
	/// `count > 0` to `!isEmpty`; `StorageUsage` must support that spelling.
	/// (swiftlint:disable:next keeps autocorrect from rewriting this body.)
	// swiftlint:disable:next empty_count
	var isEmpty: Bool { count == 0 }
}

struct StorageReport {
	let usages: [StorageUsage]
	let total: Int64
	let deviceFree: Int64
	/// Bytes the category purge rules can reclaim now, not merely all bytes in those folders.
	let reclaimable: Int64
}

enum StorageAggregateAccounting {
	/// Sums disjoint sandbox roots using the same no-follow measure used by safe deletion.
	static func totalBytes(in roots: [URL], fileManager: FileManager = .default) -> Int64 {
		roots.reduce(Int64(0)) { total, root in
			total + CleanupRemovalPolicy.allocatedSizeWithoutFollowingSymlinks(at: root, fileManager: fileManager)
		}
	}
}

struct StorageClearResult {
    let deferred: [StorageCategory]
    let freedBytes: Int64
}

enum StorageLocation: Hashable {
	case category(StorageCategory)
	case directory(URL)

	var title: String {
		switch self {
		case .category(let category): category.title
		case .directory(let url): url.lastPathComponent
		}
	}
}

struct StorageEntry: Identifiable, SortableItem {
	let id: String
	let name: String
	let version: String?
	let size: Int64
	let date: Date
	let url: URL
	let isDirectory: Bool
	let childCount: Int
	let isProtected: Bool
	let appUuid: String?

	var sortName: String { name }
	var sortDate: Date { date }
	var sortSize: Int64 { size }
}

// MARK: - Manager
@MainActor
final class StorageManager: ObservableObject {
	static let shared = StorageManager()

	@Published private(set) var report: StorageReport?
	@Published private(set) var entries: [StorageLocation: [StorageEntry]] = [:]

	private var _scan: Task<Void, Never>?

	private init() {}

	func refresh() {
		_scan?.cancel()
		_scan = Task {
			let library = _librarySnapshot()
			let scanned = await Task.detached(priority: .utility) { StorageScanner.scan(library) }.value
			guard !Task.isCancelled else { return }
			report = scanned
		}
	}

	func refreshEntries(at location: StorageLocation) async {
		let library = _librarySnapshot()
		entries[location] = await Task.detached(priority: .utility) {
			StorageScanner.entries(at: location, library)
		}.value
	}

	@discardableResult
	func delete(_ items: [StorageEntry], category: StorageCategory) -> Bool {
        let guarded = category == .temporary || category == .leftovers
        let lease = guarded ? AppOperationRegistry.shared.acquireCleanup() : nil
        if guarded && lease == nil { return false }
        defer { withExtendedLifetime(lease) {} }

        let library = _librarySnapshot()
        // Entries can outlive the scan that produced them. Re-evaluate leftovers and each
        // category's owning root while holding the cleanup lease; stale rows never authorize a path.
        let currentLeftovers = category == .leftovers ? StorageScanner.leftovers(library) : []
        guard items.allSatisfy({ !$0.isProtected && !library.protects($0.url) }) else { return false }
        guard items.allSatisfy({ _authorizedDeletionRoot(for: $0, category: category, leftovers: currentLeftovers, library: library) != nil }) else {
            return false
        }
        guard !items.isEmpty else { return true }

        var removedIDs = Set<String>()
        if category == .signed || category == .imported {
            let signed = category == .signed
            let apps = Storage.shared.getAllApps().filter { app in
                guard let uuid = app.uuid,
                      let selected = items.first(where: { $0.appUuid == uuid }),
                      app.isSigned == signed,
                      let expectedDirectory = Storage.shared.getUuidDirectory(for: app) else { return false }
                return expectedDirectory.standardizedFileURL == selected.url.standardizedFileURL
            }
            guard apps.count == items.count, Storage.shared.deleteApps(apps) else { return false }
            removedIDs = Set(items.map(\.id))
        } else {
            var allRemoved = true
            for item in items {
                guard let root = _authorizedDeletionRoot(for: item, category: category, leftovers: currentLeftovers, library: library) else {
                    allRemoved = false
                    continue
                }
                do {
                    guard try CleanupRemovalPolicy.remove(item.url, beneath: root, allowRoot: category == .other,
                        protectedRoots: library.protectedURLs) != nil else {
                        allRemoved = false
                        continue
                    }
                    removedIDs.insert(item.id)
                } catch {
                    Logger.misc.warning("Storage item deletion failed: \(LogRedaction.redact(error.localizedDescription), privacy: .public)")
                    allRemoved = false
                }
            }
            if !allRemoved { Logger.misc.warning("One or more selected storage items were retained because removal did not commit.") }
        }

        if !removedIDs.isEmpty {
            entries = entries.mapValues { $0.filter { !removedIDs.contains($0.id) } }
            refresh()
        }
        return removedIDs.count == items.count
	}

    private func _authorizedDeletionRoot(
        for item: StorageEntry,
        category: StorageCategory,
        leftovers: [URL],
        library: LibrarySnapshot
    ) -> URL? {
        let fm = FileManager.default
        let protected = library.protectedURLs
        switch category {
        case .signed, .imported:
            let signed = category == .signed
            guard let uuid = item.appUuid,
                  let app = Storage.shared.getAllApps().first(where: { $0.uuid == uuid }),
                  app.isSigned == signed,
                  let expectedDirectory = Storage.shared.getUuidDirectory(for: app),
                  expectedDirectory.standardizedFileURL == item.url.standardizedFileURL else { return nil }
            return signed ? fm.signed : fm.unsigned
        case .temporary:
            guard !TemporaryCleanupPolicy.isRetained(item.url, temporaryRoot: fm.temporaryDirectory,
                downloadStaging: fm.downloadStaging),
                CleanupRemovalPolicy.isSafeTarget(item.url, beneath: fm.temporaryDirectory, protectedRoots: protected) else { return nil }
            return fm.temporaryDirectory
        case .leftovers:
            guard Self.isWithinCurrentLeftovers(item.url, leftovers) else { return nil }
            return [fm.signed, fm.unsigned, fm.certificates].first {
                CleanupRemovalPolicy.isSafeTarget(item.url, beneath: $0, protectedRoots: protected)
            }
        case .archives:
            return CleanupRemovalPolicy.isSafeTarget(item.url, beneath: fm.archives, protectedRoots: protected) ? fm.archives : nil
        case .caches:
            let root = StorageScanner.cachesDirectory
            return CleanupRemovalPolicy.isSafeTarget(item.url, beneath: root, protectedRoots: protected) ? root : nil
        case .logs:
            return CleanupRemovalPolicy.isSafeTarget(item.url, beneath: fm.logs, protectedRoots: protected) ? fm.logs : nil
        case .other:
            let documents = URL.documentsDirectory
            let libraryDirectory = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            guard [documents, libraryDirectory].contains(where: {
                CleanupRemovalPolicy.isSafeTarget(item.url, beneath: $0, protectedRoots: protected)
            }) else { return nil }
            return StorageScanner.otherPaths().first {
                CleanupRemovalPolicy.isSafeTarget(item.url, beneath: $0, allowRoot: true, protectedRoots: protected)
            }
        default:
            return nil
        }
    }

    static func isWithinCurrentLeftovers(_ item: URL, _ leftovers: [URL]) -> Bool {
        let path = item.resolvingSymlinksInPath().standardizedFileURL.path
        return leftovers.contains {
            let root = $0.resolvingSymlinksInPath().standardizedFileURL.path
            return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
    }

	func clear(_ categories: [StorageCategory]) async -> StorageClearResult {
        let guarded = categories.filter { $0 == .temporary || $0 == .leftovers }
        let lease = guarded.isEmpty ? nil : AppOperationRegistry.shared.acquireCleanup()
        let deferred = lease == nil ? guarded : []
        let allowed = categories.filter { !deferred.contains($0) }
		let library = _librarySnapshot()
		let freedBytes = await Task.detached(priority: .utility) { () -> Int64 in
            defer { withExtendedLifetime(lease) {} }
            return allowed.reduce(Int64(0)) { $0 + StorageScanner.clear($1, library) }
		}.value

		entries.removeAll()
		refresh()
        return StorageClearResult(deferred: deferred, freedBytes: freedBytes)
	}

	private func _librarySnapshot() -> LibrarySnapshot {
		let storage = Storage.shared

		let apps = storage.getAllApps().reduce(into: [String: AppDescriptor]()) { result, app in
			guard let uuid = app.uuid else { return }
			result[uuid] = AppDescriptor(
				name: app.name ?? .localized("Unknown"),
				version: app.version,
				date: app.date ?? .distantPast,
				isSigned: app.isSigned
			)
		}

		let certificates: [String]
		let certificatesKnown: Bool
		do {
			certificates = try storage.context.fetch(CertificatePair.fetchRequest()).compactMap(\.uuid)
			certificatesKnown = true
		} catch {
			// Swallowing this used to hand cleanup an empty certificate list, which
			// reads as "no certificates installed" and deletes all of them.
			Logger.misc.error("Storage: could not read certificates; treating them as protected: \(error.localizedDescription)")
			certificates = []
			certificatesKnown = false
		}

		var protected: Set<String> = []
		if let store = storage.container.persistentStoreDescriptions.first?.url?.standardizedFileURL {
			let base = store.deletingPathExtension()
			for suffix in ["sqlite", "sqlite-wal", "sqlite-shm"] {
				protected.insert(base.appendingPathExtension(suffix).path)
			}
		}

		return LibrarySnapshot(apps: apps, certificates: Set(certificates), protected: protected,
							   certificatesKnown: certificatesKnown, productions: .shared)
	}
}

// MARK: - Manager extension: purging
extension StorageManager {
	nonisolated static func purgeCaches(protectedRoots: [URL]) -> Int64 {
		URLCache.shared.removeAllCachedResponses()
		DataLoader.sharedUrlCache.removeAllCachedResponses()
		HTTPCookieStorage.shared.removeCookies(since: .distantPast)
		(ImagePipeline.shared.configuration.dataCache as? DataCache)?.removeAll()
		ImagePipeline.shared.configuration.imageCache?.removeAll()
		// Live caches first, then the files they left behind, which is what Storage measures.
		return StorageScanner.purge(contentsOf: StorageScanner.cachesDirectory, protectedRoots: protectedRoots)
	}

    nonisolated static func purgeStaleTemporary() {
        guard let lease = AppOperationRegistry.shared.acquireCleanup() else { return }
        defer { withExtendedLifetime(lease) {} }
		let fm = FileManager.default
		let items: [URL]
		do {
			items = try fm.contentsOfDirectory(
				at: fm.temporaryDirectory,
				includingPropertiesForKeys: [.contentModificationDateKey]
			)
		} catch {
			// Nothing is deleted when the listing fails, but say so: a silent return
			// looked identical to "temporary directory already empty".
			Logger.misc.error("Storage: could not list temporary files: \(error.localizedDescription)")
			return
		}

        let staging = fm.downloadStaging.lastPathComponent
        for item in items {
            // A background download can finish while the app is dead, so staged IPAs get a day to be imported.
            if item.lastPathComponent == staging {
                do {
                    let retained = try DownloadRecoveryJournal(root: DownloadRecoveryJournal.directory).retainedStagingNames()
                    _ = StorageScanner.purge(contentsOf: item, under: fm.temporaryDirectory, olderThan: 24 * 60 * 60, preservingNames: retained)
                } catch {
                    // Protected/corrupt recovery state cannot authorize deletion of its retained inputs.
                    Logger.misc.error("Storage: retained download staging while recovery state is inaccessible.")
                }
            } else {
                if TemporaryCleanupPolicy.isRetained(item, temporaryRoot: fm.temporaryDirectory, downloadStaging: fm.downloadStaging) { continue }
                do {
                    _ = try CleanupRemovalPolicy.remove(item, beneath: fm.temporaryDirectory)
                } catch {
                    Logger.misc.warning("Storage: stale temporary cleanup failed for \(LogRedaction.redact(error.localizedDescription), privacy: .public)")
                }
            }
        }
    }
}

// MARK: - Manager extension: automatic cleanup
extension StorageManager {
	/// Bytes the automatic cleanup would reclaim for `categories` right now, without deleting
	/// anything. Only ever counts categories that are safe to clear (plus exported IPAs).
	func reclaimableBytes(_ categories: [StorageCategory]) -> Int64 {
		let library = _librarySnapshot()
		return categories.reduce(0) { $0 + StorageScanner.reclaimableBytes($1, library) }
	}

	/// Per-category breakdown for the cleanup settings screen.
	func reclaimableBreakdown() -> [(category: StorageCategory, bytes: Int64)] {
		let library = _librarySnapshot()
		return [StorageCategory.caches, .temporary, .leftovers, .archives, .logs]
			.map { (category: $0, bytes: StorageScanner.reclaimableBytes($0, library)) }
	}

	/// Deletes one reclaimable category and returns how many bytes were freed.
	///
	/// Nothing here can touch app bundles, certificates or the database — only the caches,
	/// temporary work files, leftovers and exported IPAs the user asked to be rid of.
	@discardableResult
	func purge(_ category: StorageCategory, cleanupLease: AppOperationRegistry.Lease? = nil) -> Int64 {
        let guarded = category == .temporary || category == .leftovers
        let lease = cleanupLease ?? (guarded ? AppOperationRegistry.shared.acquireCleanup() : nil)
        if guarded && lease == nil { return 0 }
        defer { withExtendedLifetime(lease) {} }
		let library = _librarySnapshot()
        let freed: Int64
        switch category {
        case .caches:
            freed = StorageManager.purgeCaches(protectedRoots: library.protectedURLs)
        case .logs:
            freed = StorageScanner.purge(contentsOf: FileManager.default.logs, protectedRoots: library.protectedURLs)
        case .temporary:
            freed = StorageScanner.purgeTemporary(protectedRoots: library.protectedURLs)
        case .leftovers:
            freed = StorageScanner.purgeLeftovers(library)
        case .archives:
            freed = StorageScanner.purge(contentsOf: FileManager.default.archives, protectedRoots: library.protectedURLs)
        default:
            return 0
        }
        guard freed > 0 else { return 0 }

		SigningLog.shared.info(
			.localized("Purged %@: freed %@", arguments: category.title, ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)),
			category: "storage"
		)

		entries.removeAll()
		refresh()
		return freed
	}
}

// MARK: - Library snapshot
struct AppDescriptor {
	let name: String
	let version: String?
	let date: Date
	let isSigned: Bool
}

struct LibrarySnapshot {
	let apps: [String: AppDescriptor]
	let certificates: Set<String>
	let protected: Set<String>
	/// False when the certificate fetch failed. An empty `certificates` then means
	/// "unknown", not "none": treating it as none would make every installed
	/// certificate look like an orphan and `clear(.leftovers)` would delete it.
	var certificatesKnown: Bool = true
	/// Where copies that are being produced announce themselves.
	///
	/// `apps` is read once, and the folders are judged afterwards: seconds later for a large
	/// library, and off the main thread when the user clears storage by hand. A copy that is
	/// signed or imported in between has a folder and no row in `apps`, which is what a
	/// leftover looks like, and `clear(.leftovers)` deleted the bundle of an app that had just
	/// been registered. So this is asked when a folder is judged, not when the snapshot is taken.
	var productions: AppOperationRegistry?

	func owns(_ uuid: String, signed: Bool) -> Bool {
		if apps[uuid]?.isSigned == signed { return true }
		return productions?.knowsProduction(of: uuid) == true
	}

	/// Fail closed: with no certificate list, nothing is an orphan.
	func ownsCertificate(_ uuid: String) -> Bool {
		certificatesKnown ? certificates.contains(uuid) : true
	}

    var protectedURLs: [URL] { protected.map { URL(fileURLWithPath: $0) } }

	func protects(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return protectedURLs.contains { protectedURL in
            let protectedPath = protectedURL.resolvingSymlinksInPath().standardizedFileURL.path
            let pathPrefix = path.hasSuffix("/") ? path : path + "/"
            let protectedPrefix = protectedPath.hasSuffix("/") ? protectedPath : protectedPath + "/"
            return protectedPath == path || protectedPath.hasPrefix(pathPrefix) || path.hasPrefix(protectedPrefix)
        }
	}
}

// MARK: - Scanner
enum StorageScanner {
	static let fm = FileManager.default

	struct Partition {
		var size: Int64 = 0
		var count = 0
		var orphans: [URL] = []
		var orphanSize: Int64 = 0
	}

	static func scan(_ library: LibrarySnapshot) -> StorageReport {
		let signed = partition(fm.signed) { library.owns($0, signed: true) }
		let imported = partition(fm.unsigned) { library.owns($0, signed: false) }
		let certificates = partition(fm.certificates) { library.ownsCertificate($0) }

		// The Web Manager inbox contains user-owned transfers and is not part of the
		// automatic leftovers purge, so it must not inflate this reclaimable category.
		let leftoverSize = signed.orphanSize + imported.orphanSize + certificates.orphanSize
		let leftoverCount = signed.orphans.count + imported.orphans.count + certificates.orphans.count

		let other = otherPaths()

		let usages: [StorageUsage] = [
			StorageUsage(category: .signed, size: signed.size, count: signed.count),
			StorageUsage(category: .imported, size: imported.size, count: imported.count),
			StorageUsage(category: .leftovers, size: leftoverSize, count: leftoverCount),
			StorageUsage(category: .certificates, size: certificates.size, count: certificates.count),
			StorageUsage(category: .other, size: other.reduce(0) { $0 + CleanupRemovalPolicy.allocatedSizeWithoutFollowingSymlinks(at: $1) }, count: other.count),
			measure(.archives, fm.archives),
			measure(.tweaks, fm.tweaksLibrary),
			measure(.logs, fm.logs),
			measure(.temporary, fm.temporaryDirectory),
			measure(.caches, cachesDirectory)
		]

		let reclaimable = StorageCategory.safeToClear.reduce(Int64(0)) { total, category in
			total + reclaimableBytes(category, library)
		}
		return StorageReport(
			usages: usages.filter { $0.size > 0 },
			total: StorageAggregateAccounting.totalBytes(in: [URL.documentsDirectory, libraryDirectory, fm.temporaryDirectory]),
			deviceFree: fm.availableImportantCapacity(at: URL.documentsDirectory) ?? 0,
			reclaimable: reclaimable
		)
	}

	static func entries(at location: StorageLocation, _ library: LibrarySnapshot) -> [StorageEntry] {
		switch location {
		case .directory(let url):
			return contents(of: url).map { entry($0, library) }
		case .category(let category):
			return categoryEntries(category, library)
		}
	}

	static func clear(_ category: StorageCategory, _ library: LibrarySnapshot) -> Int64 {
		switch category {
		case .caches:
			return StorageManager.purgeCaches(protectedRoots: library.protectedURLs)
		case .logs:
            return purge(contentsOf: fm.logs, protectedRoots: library.protectedURLs)
		case .temporary:
            return purgeTemporary(protectedRoots: library.protectedURLs)
		case .leftovers:
            return purgeLeftovers(library)
		case .archives:
            return purge(contentsOf: fm.archives, protectedRoots: library.protectedURLs)
		default:
			return 0
		}
	}

	/// Bytes the cleanup toggle for `category` would free, using the same rules the purge uses.
	static func reclaimableBytes(_ category: StorageCategory, _ library: LibrarySnapshot) -> Int64 {
		switch category {
		case .caches:
            return purgeableSize(in: cachesDirectory, protectedRoots: library.protectedURLs)
		case .logs:
            return purgeableSize(in: fm.logs, protectedRoots: library.protectedURLs)
		case .temporary:
            return temporarySize(protectedRoots: library.protectedURLs)
		case .leftovers:
            return leftovers(library).reduce(0) { total, url in
                guard [fm.signed, fm.unsigned, fm.certificates].contains(where: {
                    CleanupRemovalPolicy.isSafeTarget(url, beneath: $0, protectedRoots: library.protectedURLs)
                }) else { return total }
                return total + CleanupRemovalPolicy.allocatedSizeWithoutFollowingSymlinks(at: url)
            }
		case .archives:
            return purgeableSize(in: fm.archives, protectedRoots: library.protectedURLs)
		default:
			return 0
		}
	}

	/// Clears temporary children except artifacts whose owner or Undo offer may still be live.
    @discardableResult
	static func purgeTemporary(protectedRoots: [URL]) -> Int64 {
        guard CleanupRemovalPolicy.isDirectoryRoot(fm.temporaryDirectory) else { return 0 }
        var freed: Int64 = 0
		for url in contents(of: fm.temporaryDirectory) {
            if TemporaryCleanupPolicy.isRetained(url, temporaryRoot: fm.temporaryDirectory, downloadStaging: fm.downloadStaging) { continue }
            do {
                if let removed = try CleanupRemovalPolicy.remove(url, beneath: fm.temporaryDirectory, protectedRoots: protectedRoots) {
                    freed += removed
                }
            } catch {
                Logger.misc.warning("Temporary cleanup failed: \(LogRedaction.redact(error.localizedDescription), privacy: .public)")
            }
		}
        return freed
	}

	private static func temporarySize(protectedRoots: [URL]) -> Int64 {
        guard CleanupRemovalPolicy.isDirectoryRoot(fm.temporaryDirectory) else { return 0 }
		return contents(of: fm.temporaryDirectory).reduce(0) { total, url in
            guard !TemporaryCleanupPolicy.isRetained(url, temporaryRoot: fm.temporaryDirectory, downloadStaging: fm.downloadStaging),
                  CleanupRemovalPolicy.isSafeTarget(url, beneath: fm.temporaryDirectory, protectedRoots: protectedRoots) else { return total }
			return total + CleanupRemovalPolicy.allocatedSizeWithoutFollowingSymlinks(at: url)
		}
	}

    static func purgeLeftovers(_ library: LibrarySnapshot) -> Int64 {
        var freed: Int64 = 0
        let roots = [fm.signed, fm.unsigned, fm.certificates]
        for url in leftovers(library) {
            guard let root = roots.first(where: {
                CleanupRemovalPolicy.isSafeTarget(url, beneath: $0, protectedRoots: library.protectedURLs)
            }) else { continue }
            do {
                if let removed = try CleanupRemovalPolicy.remove(url, beneath: root, protectedRoots: library.protectedURLs) {
                    freed += removed
                }
            } catch {
                Logger.misc.warning("Leftover cleanup failed: \(LogRedaction.redact(error.localizedDescription), privacy: .public)")
            }
        }
        return freed
    }

	static func purge(
        contentsOf directory: URL,
        under authorizedRoot: URL? = nil,
        olderThan age: TimeInterval? = nil,
        preservingNames: Set<String> = [],
        protectedRoots: [URL] = []
    ) -> Int64 {
        guard CleanupRemovalPolicy.isDirectoryRoot(directory) else { return 0 }
        if let authorizedRoot, !CleanupRemovalPolicy.isSafeDirectory(directory, beneath: authorizedRoot) { return 0 }
        var freed: Int64 = 0
		for url in contents(of: directory) {
            if preservingNames.contains(url.lastPathComponent) { continue }
            if let age {
                do {
                    guard let modified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                          Date().timeIntervalSince(modified) >= age else { continue }
                } catch {
                    Logger.misc.warning("Retained cleanup item with unreadable modification date.")
                    continue
                }
            }
            do {
                if let removed = try CleanupRemovalPolicy.remove(url, beneath: directory, protectedRoots: protectedRoots) {
                    freed += removed
                }
            } catch {
                Logger.misc.warning("Storage purge failed: \(LogRedaction.redact(error.localizedDescription), privacy: .public)")
            }
		}
        return freed
	}

    static func purgeableSize(in directory: URL, protectedRoots: [URL]) -> Int64 {
        guard CleanupRemovalPolicy.isDirectoryRoot(directory) else { return 0 }
        return contents(of: directory).reduce(0) { total, url in
            guard CleanupRemovalPolicy.isSafeTarget(url, beneath: directory, protectedRoots: protectedRoots) else { return total }
            return total + CleanupRemovalPolicy.allocatedSizeWithoutFollowingSymlinks(at: url)
        }
    }

	// MARK: Entries

	private static func categoryEntries(_ category: StorageCategory, _ library: LibrarySnapshot) -> [StorageEntry] {
		switch category {
		case .signed, .imported:
			let signed = category == .signed
			return contents(of: signed ? fm.signed : fm.unsigned).compactMap { url in
				let uuid = url.lastPathComponent
				guard let app = library.apps[uuid], app.isSigned == signed else { return nil }
				return StorageEntry(
					id: uuid,
					name: app.name,
					version: app.version,
					size: CleanupRemovalPolicy.allocatedSizeWithoutFollowingSymlinks(at: url),
					date: app.date,
					url: url,
					isDirectory: true,
					childCount: 0,
					isProtected: false,
					appUuid: uuid
				)
			}
		case .archives:
			return contents(of: fm.archives).map { entry($0, library) }
		case .leftovers:
			return leftovers(library).map { entry($0, library) }
		case .caches:
			return contents(of: cachesDirectory).map { entry($0, library) }
		case .temporary:
			return contents(of: fm.temporaryDirectory).map { entry($0, library) }
		case .logs:
			return contents(of: fm.logs).map { entry($0, library) }
		case .other:
			return otherPaths().map { entry($0, library) }
		case .tweaks, .certificates:
			return []
		}
	}

	static func otherPaths() -> [URL] {
		let claimed = Set(
			[fm.signed, fm.unsigned, fm.certificates, fm.archives, fm.tweaksLibrary, fm.logs, fm.webManagerInbox]
				.map(\.lastPathComponent)
		)

		return contents(of: URL.documentsDirectory).filter { !claimed.contains($0.lastPathComponent) }
			+ contents(of: libraryDirectory).filter { $0.lastPathComponent != cachesDirectory.lastPathComponent }
	}

	private static func entry(_ url: URL, _ library: LibrarySnapshot) -> StorageEntry {
		let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey]) // try? ok: display metadata for a storage row; a file that cannot be statted shows as a non-directory
		let isDirectory = values?.isDirectory == true

		return StorageEntry(
			id: url.path,
			name: url.lastPathComponent,
			version: nil,
			size: CleanupRemovalPolicy.allocatedSizeWithoutFollowingSymlinks(at: url),
			date: values?.contentModificationDate ?? .distantPast,
			url: url,
			isDirectory: isDirectory,
			childCount: isDirectory ? contents(of: url).count : 0,
			isProtected: library.protects(url),
			appUuid: nil
		)
	}

	// Not `private`: `StorageManager.purge(_:)` (an extension of a different type in
	// this same file) calls this, and `private` would limit access to StorageScanner
	// and its own extensions. The enclosing enum is file-scoped anyway.
	static func leftovers(_ library: LibrarySnapshot) -> [URL] {
		partition(fm.signed) { library.owns($0, signed: true) }.orphans
		+ partition(fm.unsigned) { library.owns($0, signed: false) }.orphans
		+ partition(fm.certificates) { library.ownsCertificate($0) }.orphans
        // Web Manager inbox files are user-owned transfers, not orphans. They
        // include partial uploads, pending routes and files intentionally retained.
        // Manage them explicitly in Web Manager, never via automatic cleanup.
	}

	// MARK: Measuring

	private static func partition(_ directory: URL, isKnown: (String) -> Bool) -> Partition {
		var partition = Partition()

		for url in contents(of: directory) {
			let size = CleanupRemovalPolicy.allocatedSizeWithoutFollowingSymlinks(at: url)
			if isKnown(url.lastPathComponent) {
				partition.size += size
				partition.count += 1
			} else {
				partition.orphans.append(url)
				partition.orphanSize += size
			}
		}

		return partition
	}

	private static func contents(of directory: URL) -> [URL] {
		(try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] // try? ok: listing a directory that may not exist yet; no entries is the correct answer then
	}

	private static func measure(_ category: StorageCategory, _ directory: URL) -> StorageUsage {
		StorageUsage(
			category: category,
			size: CleanupRemovalPolicy.allocatedSizeWithoutFollowingSymlinks(at: directory),
			count: contents(of: directory).count
		)
	}

	static var cachesDirectory: URL {
		fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
	}

	private static var libraryDirectory: URL {
		fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
	}
}
