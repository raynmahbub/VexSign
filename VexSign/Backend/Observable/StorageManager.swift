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

	var reclaimable: Int64 {
		usages
			.filter { StorageCategory.safeToClear.contains($0.category) }
			.reduce(0) { $0 + $1.size }
	}
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
        // Entries can outlive the scan that produced them. Re-evaluate leftovers while
        // holding the cleanup lease instead of trusting the old isProtected flag.
        let currentLeftovers = category == .leftovers ? StorageScanner.leftovers(_librarySnapshot()) : []
        let deletable = items.filter { item in
            let retained = category == .temporary && TemporaryCleanupPolicy.isRetained(
                item.url, temporaryRoot: FileManager.default.temporaryDirectory,
                downloadStaging: FileManager.default.downloadStaging)
            let stillLeftover = category != .leftovers || Self.isWithinCurrentLeftovers(item.url, currentLeftovers)
            return !item.isProtected && stillLeftover && !retained
        }
        guard deletable.count == items.count else { return false }
		guard !deletable.isEmpty else { return true }

		let uuids = Set(deletable.compactMap(\.appUuid))
		if !uuids.isEmpty {
			Storage.shared.deleteApps(Storage.shared.getAllApps().filter { uuids.contains($0.uuid ?? "") })
		}

		for item in deletable where item.appUuid == nil {
			try? FileManager.default.removeItem(at: item.url) // try? ok: deleting an unclaimed file during an explicit user cleanup; the entry leaves the report either way
		}

		let removed = Set(deletable.map(\.id))
		entries = entries.mapValues { $0.filter { !removed.contains($0.id) } }
		refresh()
        return true
	}

    static func isWithinCurrentLeftovers(_ item: URL, _ leftovers: [URL]) -> Bool {
        let path = item.standardizedFileURL.path
        return leftovers.contains {
            let root = $0.standardizedFileURL.path
            return path == root || path.hasPrefix(root + "/")
        }
    }

	@discardableResult
	func clear(_ categories: [StorageCategory]) async -> [StorageCategory] {
        let guarded = categories.filter { $0 == .temporary || $0 == .leftovers }
        let lease = guarded.isEmpty ? nil : AppOperationRegistry.shared.acquireCleanup()
        let deferred = lease == nil ? guarded : []
        let allowed = categories.filter { !deferred.contains($0) }
		let library = _librarySnapshot()
		await Task.detached(priority: .utility) {
            defer { withExtendedLifetime(lease) {} }
			for category in allowed { StorageScanner.clear(category, library) }
		}.value

		entries.removeAll()
		refresh()
        return deferred
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
	nonisolated static func purgeCaches() {
		URLCache.shared.removeAllCachedResponses()
		DataLoader.sharedUrlCache.removeAllCachedResponses()
		HTTPCookieStorage.shared.removeCookies(since: .distantPast)
		(ImagePipeline.shared.configuration.dataCache as? DataCache)?.removeAll()
		ImagePipeline.shared.configuration.imageCache?.removeAll()
		// Live caches first, then the files they left behind, which is what Storage measures.
		StorageScanner.purge(contentsOf: StorageScanner.cachesDirectory)
	}

nonisolated static func purgeTemporary() {
        guard let lease = AppOperationRegistry.shared.acquireCleanup() else { return }
        defer { withExtendedLifetime(lease) {} }
        StorageScanner.purgeTemporary()
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
                    StorageScanner.purge(contentsOf: item, olderThan: 24 * 60 * 60, preservingNames: retained)
                } catch {
                    // Protected/corrupt recovery state cannot authorize deletion of its retained inputs.
                    Logger.misc.error("Storage: retained download staging while recovery state is inaccessible.")
                }
			} else {
				try? fm.removeItem(at: item) // try? ok: best-effort temporary cleanup; a file in use stays and is retried on the next pass
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
		let before = StorageScanner.reclaimableBytes(category, library)
		guard before > 0 else { return 0 }

		switch category {
		case .caches:
			StorageManager.purgeCaches()
		case .logs:
			FileLogger.clear()
		case .temporary:
			StorageScanner.purgeTemporary()
		case .leftovers:
			for url in StorageScanner.leftovers(library) { try? FileManager.default.removeItem(at: url) } // try? ok: explicit user cleanup; a file that refuses to delete is reported again by the next scan
		case .archives:
			StorageScanner.purge(contentsOf: FileManager.default.archives)
		default:
			return 0
		}

		SigningLog.shared.info(
			.localized("Purged %@: freed %@", arguments: category.title, ByteCountFormatter.string(fromByteCount: before, countStyle: .file)),
			category: "storage"
		)

		entries.removeAll()
		refresh()
		return before
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

	func protects(_ url: URL) -> Bool {
		let path = url.standardizedFileURL.path
		return protected.contains { $0 == path || $0.hasPrefix(path + "/") }
	}
}

// MARK: - Scanner
private enum StorageScanner {
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

		let inbox = contents(of: fm.webManagerInbox)
		let leftoverSize = signed.orphanSize + imported.orphanSize + certificates.orphanSize
			+ inbox.reduce(0) { $0 + fm.allocatedSize(at: $1) }
		let leftoverCount = signed.orphans.count + imported.orphans.count + certificates.orphans.count + inbox.count

		let other = otherPaths()

		let usages: [StorageUsage] = [
			StorageUsage(category: .signed, size: signed.size, count: signed.count),
			StorageUsage(category: .imported, size: imported.size, count: imported.count),
			StorageUsage(category: .leftovers, size: leftoverSize, count: leftoverCount),
			StorageUsage(category: .certificates, size: certificates.size, count: certificates.count),
			StorageUsage(category: .other, size: other.reduce(0) { $0 + fm.allocatedSize(at: $1) }, count: other.count),
			measure(.archives, fm.archives),
			measure(.tweaks, fm.tweaksLibrary),
			measure(.logs, fm.logs),
			measure(.temporary, fm.temporaryDirectory),
			measure(.caches, cachesDirectory)
		]

		return StorageReport(
			usages: usages.filter { $0.size > 0 },
			total: fm.allocatedSize(at: URL.documentsDirectory)
				+ fm.allocatedSize(at: libraryDirectory)
				+ fm.allocatedSize(at: fm.temporaryDirectory),
			deviceFree: fm.availableImportantCapacity(at: URL.documentsDirectory) ?? 0
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

	static func clear(_ category: StorageCategory, _ library: LibrarySnapshot) {
		switch category {
		case .caches:
			StorageManager.purgeCaches()
		case .logs:
			FileLogger.clear()
		case .temporary:
            purgeTemporary()
		case .leftovers:
			for url in leftovers(library) { try? fm.removeItem(at: url) } // try? ok: explicit user cleanup; a file that refuses to delete is reported again by the next scan
		case .archives:
			purge(contentsOf: fm.archives)
		default:
			break
		}
	}

	/// Bytes the cleanup toggle for `category` would free, using the same rules the purge uses.
	static func reclaimableBytes(_ category: StorageCategory, _ library: LibrarySnapshot) -> Int64 {
		switch category {
		case .caches:
			return fm.allocatedSize(at: cachesDirectory)
		case .logs:
			return fm.allocatedSize(at: fm.logs)
		case .temporary:
			return temporarySize()
		case .leftovers:
			return leftovers(library).reduce(0) { $0 + fm.allocatedSize(at: $1) }
		case .archives:
			return fm.allocatedSize(at: fm.archives)
		default:
			return 0
		}
	}

	/// Clears the temporary directory. Ran while a background download is still staged would kill
	/// it, so the download staging folder is always kept, including for manual cleanup.
	static func purgeTemporary() {
		for url in contents(of: fm.temporaryDirectory) {
            if TemporaryCleanupPolicy.isRetained(url, temporaryRoot: fm.temporaryDirectory, downloadStaging: fm.downloadStaging) { continue }
			try? fm.removeItem(at: url) // try? ok: best-effort temporary cleanup, honouring the retention policy above
		}
	}

	private static func temporarySize() -> Int64 {
		return contents(of: fm.temporaryDirectory).reduce(0) { total, url in
            if TemporaryCleanupPolicy.isRetained(url, temporaryRoot: fm.temporaryDirectory, downloadStaging: fm.downloadStaging) { return total }
			return total + fm.allocatedSize(at: url)
		}
	}

	static func purge(contentsOf directory: URL, olderThan age: TimeInterval? = nil, preservingNames: Set<String> = []) {
		for url in contents(of: directory) {
            if preservingNames.contains(url.lastPathComponent) { continue }
			if
				let age,
				let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, // try? ok: an entry with no readable modification date is treated as old, which is the existing behaviour
				Date().timeIntervalSince(modified) < age {
				continue
			}
			try? fm.removeItem(at: url) // try? ok: best-effort purge; whatever survives is still measured and reported
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
					size: fm.allocatedSize(at: url),
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

	private static func otherPaths() -> [URL] {
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
			size: fm.allocatedSize(at: url),
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
			let size = fm.allocatedSize(at: url)
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
			size: fm.allocatedSize(at: directory),
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
