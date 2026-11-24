//
//  Persistence.swift
//  VexSign
//
//  Created by VexSign Team on 10.04.2025.
//  Created by VexSign Team
//

import CoreData
import Foundation
import OSLog

// MARK: - Storage
final class Storage: ObservableObject {
    enum PersistenceError: LocalizedError, Equatable {
        case persistentStorageUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .persistentStorageUnavailable(let reason):
                return "Persistent storage is unavailable (\(reason)). Write operations are disabled to protect your library; export diagnostics or restart VexSign to recover."
            }
        }
    }

    static let shared = Storage()
    let container: NSPersistentContainer
    @Published private(set) var recoveryNotice: CoreDataStoreRecovery.Notice?
    @Published private(set) var isPersistentStorageUnavailable = false
    @Published private(set) var persistenceUnavailableReason: String?
    @Published private(set) var quarantinedStoreDirectory: URL?

    private let _name: String = "VexSign"
    private let _inMemory: Bool
    private let _customQuarantineRoot: URL?
    private let _forcePersistentStoreFailure: Bool
    private let _availabilityLock = NSLock()
    private var _persistentStorageUnavailableState = false
    private var _persistentStorageUnavailableReasonState: String?

    var persistentStorageUnavailableError: PersistenceError? {
        _availabilityLock.lock()
        defer { _availabilityLock.unlock() }
        guard _persistentStorageUnavailableState else { return nil }
        let reason = _persistentStorageUnavailableReasonState ?? "The library database could not be opened."
        return .persistentStorageUnavailable(reason)
    }

	/// One model instance per process, shared by every `Storage`.
	///
	/// `NSPersistentContainer(name:)` builds a fresh `NSManagedObjectModel` on
	/// every call, and two models describing the same entities make Core Data
	/// choose between them when it faults a row in: it logs "Failed to find a
	/// unique match for an NSEntityDescription to a managed object subclass" and
	/// can hand back an unmapped `Imported`. The app's store and the in-memory
	/// stores the test bundle creates live in one process, which is exactly that
	/// situation - and the log from the test host has the message in it.
	private static let _sharedModel: NSManagedObjectModel? = {
		guard
			let url = Bundle.main.url(forResource: "VexSign", withExtension: "momd"),
			let model = NSManagedObjectModel(contentsOf: url)
		else {
			return nil
		}
		return model
	}()
/// Private-queue context owned by `write(_:)`. Created on first use and only ever
/// touched from inside `perform`, which serialises writers.
///
/// Creation is guarded by a lock. `write` is called from arbitrary tasks, and a
/// `lazy var` is not safe to initialise from two threads: concurrent first writers
/// could each receive their own context, which removes the serialisation every
/// writer relies on (two inserts then read the same lowest `sortIndex`).
private let _writeContextLock = NSLock()
private var _writeContextStorage: NSManagedObjectContext?
private var _writeContext: NSManagedObjectContext {
	_writeContextLock.lock()
	defer { _writeContextLock.unlock() }
	if let existing = _writeContextStorage { return existing }
	let writeContext = container.newBackgroundContext()
	writeContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
	writeContext.automaticallyMergesChangesFromParent = true
	writeContext.undoManager = nil
	_writeContextStorage = writeContext
	return writeContext
}

    init(inMemory: Bool = false) {
        _inMemory = inMemory
        _customQuarantineRoot = nil
        _forcePersistentStoreFailure = false

        // Migrate legacy store file if exists (Feather.sqlite -> VexSign.sqlite) to preserve user data
        var legacyStoreIsStillInUse = false
        if !inMemory, let migrationFailure = Self._migrateLegacyStoreIfNeeded() {
            // The move failed, and `Feather.sqlite` still holds the user's library. Opening a
            // fresh `VexSign.sqlite` beside it would read as "all my apps are gone", so the
            // container is pointed at the legacy file instead: the library keeps working, and
            // the next launch retries the move.
            Logger.misc.fault(
                "Opening the legacy store in place because it could not be migrated: \(LogRedaction.redact(migrationFailure.localizedDescription), privacy: .public)"
            )
            legacyStoreIsStillInUse = true
        }

        if let model = Self._sharedModel {
            container = NSPersistentContainer(name: _name, managedObjectModel: model)
        } else {
            container = NSPersistentContainer(name: _name)
        }

        if inMemory {
            // An in-memory description, not a SQLite store pointed at /dev/null:
            // the file-backed load path reports an error for that URL, and the
            // recovery below reacts to an error by deleting the store files.
            let description = NSPersistentStoreDescription()
            description.type = NSInMemoryStoreType
            container.persistentStoreDescriptions = [description]
        } else if legacyStoreIsStillInUse,
                  let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            // Same store, same schema — just where the migration could not move it from.
            let description = NSPersistentStoreDescription(url: support.appendingPathComponent("Feather.sqlite"))
            description.type = NSSQLiteStoreType
            description.shouldMigrateStoreAutomatically = true
            description.shouldInferMappingModelAutomatically = true
            container.persistentStoreDescriptions = [description]
            _legacyStoreIsLive = true
        }

        _loadPersistentStoreAggressively()
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        _migrateSortIndexIfNeeded()
    }

    /// Creates a file-backed store rooted at an explicit SQLite URL so tests can
    /// exercise corruption recovery, degraded unavailability, and cross-restart persistence
    /// without touching the live app library.
    init(
        storeURL: URL,
        quarantineRoot: URL? = nil,
        forcePersistentStoreFailure: Bool = false
    ) {
        _inMemory = false
        _customQuarantineRoot = quarantineRoot
        _forcePersistentStoreFailure = forcePersistentStoreFailure

        if let model = Self._sharedModel {
            container = NSPersistentContainer(name: _name, managedObjectModel: model)
        } else {
            container = NSPersistentContainer(name: _name)
        }

        let description = NSPersistentStoreDescription(url: storeURL)
        description.type = NSSQLiteStoreType
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
        container.persistentStoreDescriptions = [description]

        _loadPersistentStoreAggressively()
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }
	
	// MARK: - Concurrency contract
	//
	// There are exactly two ways to touch the store:
	//
	//   * reads and UI edits - `context` (the view context) on the main queue,
	//     from `@MainActor` code such as SwiftUI views and main-isolated
	//     managers;
	//   * writes started from a detached task (signing, importing, cloning) -
	//     `write(_:)`, which runs on the private-queue write context and hands
	//     back an `NSManagedObjectID` instead of a managed object.
	//
	// Managed objects belong to the queue that fetched them. Handing one to a
	// detached task and inserting with it is what used to make library writes
	// race the main queue; the ID is the boundary that makes that mistake
	// impossible to express by accident.

	var context: NSManagedObjectContext {
		container.viewContext
	}

	/// A read that cannot be answered from the model at all.
	///
	/// Core Data does not fail a request whose entity name it cannot find: it *raises*
	/// (`NSFetchRequest could not locate an NSEntityDescription`), and an Objective-C exception
	/// ends the process instead of reaching a caller that could report it. Both read accessors
	/// therefore ask the model first, so a wrong name is an empty answer or a Swift error
	/// depending on which contract the caller signed up for.
	enum ReadFailure: LocalizedError, Equatable {
		case unknownEntity(String)

		var errorDescription: String? {
			switch self {
			case .unknownEntity(let name):
				return "\(name) is not part of the VexSign data model, so there is nothing to read from it."
			}
		}
	}

	/// The entity name a request asks for when the model does not carry it.
	private func unknownEntityName<T>(in request: NSFetchRequest<T>) -> String? {
		guard let name = request.entityName,
		      container.managedObjectModel.entitiesByName[name] == nil else { return nil }
		return name
	}

	/// Fetches on the view context's own queue, whoever the caller is.
	///
	/// `context.fetch` may only run on the queue that owns the context - the
	/// main queue here - and a read accessor reached from a detached task used
	/// to be a SIGTRAP in a debug build (`_PFAssertSafeMultiThreadedAccess`,
	/// which is what killed the test host before the test bundle connected).
	/// The caller stays synchronous; only the fetch changes queue, and
	/// `performAndWait` runs inline when the caller is already on it.
	func fetchOnQueue<T>(_ request: NSFetchRequest<T>) -> [T] {
		guard unknownEntityName(in: request) == nil else { return [] }
		let context = self.context
		var results: [T] = []
		context.performAndWait {
			results = (try? context.fetch(request)) ?? [] // try? ok: an unreadable store yields no rows, which every caller already treats as empty
		}
		return results
	}

	/// Same queue contract as `fetchOnQueue`, but a read failure is reported instead of being
	/// flattened into an empty result.
	///
	/// `fetchOnQueue` answers "no rows" for a store it could not read, and that is right for the
	/// optional lookups around it: an unavailable artifact is a missing artifact. It is wrong for
	/// the catalog read behind the Library, where "no rows" is rendered as an empty library - an
	/// import that committed looks like an import that never happened, and nothing anywhere says
	/// otherwise. Callers that can say why use this one.
	func fetchOnQueueThrowing<T>(_ request: NSFetchRequest<T>) throws -> [T] {
		if let name = unknownEntityName(in: request) { throw ReadFailure.unknownEntity(name) }
		let context = self.context
		var result: Result<[T], Error> = .success([])
		context.performAndWait {
			result = Result { try context.fetch(request) }
		}
		return try result.get()
	}

	/// Runs `changes` on the private-queue write context, saves it, and returns
	/// the permanent object ID of the row the block inserted or updated.
	///
	/// The block runs on the write context and must do all of its work there. It
	/// may return a managed object - `write` only reads its `objectID`, after the
	/// save - but the caller must not use, store or return that object. Resolve
	/// the returned ID with `object(_:)` on the main actor.
	///
	/// Saves are visible to `context` through
	/// `automaticallyMergesChangesFromParent`, so `@FetchRequest` lists update
	/// exactly as they did when inserts ran on the view context.
	///
	/// - Throws: whatever the block throws; the context is rolled back first, so
	///   a failed write leaves no row behind.
    func write(
        _ changes: @escaping (NSManagedObjectContext) throws -> NSManagedObject
    ) async throws -> NSManagedObjectID {
        if let unavailableError = persistentStorageUnavailableError {
            throw unavailableError
        }
        let context = _writeContext
        return try await withCheckedThrowingContinuation { continuation in
            context.perform {
                do {
                    if let unavailableError = self.persistentStorageUnavailableError {
                        throw unavailableError
                    }
                    let object = try changes(context)
                    if context.hasChanges {
                        try context.save()
                    }
                    // Read after the save: a temporary ID only becomes permanent
                    // once the row exists in the store, and only a permanent ID can
                    // be resolved again later.
                    continuation.resume(returning: object.objectID)
                } catch {
                    context.rollback()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Resolves an ID returned by `write(_:)` on the main-queue context.
    @MainActor
    func object<T: NSManagedObject>(_ id: NSManagedObjectID) -> T? {
        guard !id.isTemporaryID else { return nil }
        return (try? context.existingObject(with: id)) as? T // try? ok: optional object lookup; nil when the row is gone
    }

    func saveContext() {
        StorageConcurrency.requireMainQueue()
        if let unavailableError = persistentStorageUnavailableError {
            let redacted = LogRedaction.redact(unavailableError.localizedDescription)
            Logger.misc.fault("Refused CoreData save while persistent storage is unavailable: \(redacted, privacy: .public)")
            if Thread.isMainThread {
                context.rollback()
            } else {
                DispatchQueue.main.async {
                    self.context.rollback()
                }
            }
            return
        }
        // Save sync if already on main to avoid a deadlock
        if Thread.isMainThread {
            if context.hasChanges {
                do {
                    try context.save()
                } catch {
                    Logger.misc.error("CoreData save failed: \(error.localizedDescription)")
                }
            }
        } else {
            DispatchQueue.main.async {
                if self.context.hasChanges {
                    do {
                        try self.context.save()
                    } catch {
                        Logger.misc.error("CoreData save failed: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    /// Deletes every row of one entity.
    ///
    /// A batch delete goes straight to the store and never touches the view context's
    /// object graph: rows the context already holds stay visible, so the "count" rows
    /// drop to zero while lists built from the same context keep showing them until the
    /// app relaunches. `deleteAppsWithOutcome` merges its deletions for exactly this
    /// reason; the clear paths did not.
    func clearContext<T: NSManagedObject>(request: NSFetchRequest<T>) {
        StorageConcurrency.requireMainQueue()
        guard persistentStorageUnavailableError == nil else {
            Logger.misc.fault("Refused clearing CoreData rows while persistent storage is unavailable.")
            return
        }
        guard let entityName = request.entityName else { return }
        let deleteRequest = NSFetchRequest<NSFetchRequestResult>(entityName: entityName)
        deleteRequest.includesPropertyValues = false

        // IDs only: a delete-all should not fault every row into the view context just to
        // learn their identities.
        let idRequest = NSFetchRequest<NSManagedObjectID>(entityName: entityName)
        idRequest.resultType = .managedObjectIDResultType

        let ids: [NSManagedObjectID]
        do {
            ids = try context.fetch(idRequest)
        } catch {
            Logger.misc.error("Could not read rows to clear: \(LogRedaction.redact(error.localizedDescription), privacy: .public)")
            return
        }
        guard !ids.isEmpty else { return }

        do {
            _ = try context.execute(NSBatchDeleteRequest(fetchRequest: deleteRequest))
        } catch {
            Logger.misc.error("Batch delete failed: \(LogRedaction.redact(error.localizedDescription), privacy: .public)")
            return
        }
        NSManagedObjectContext.mergeChanges(fromRemoteContextSave: [NSDeletedObjectsKey: ids], into: [context])
    }

    func countContent<T: NSManagedObject>(for type: T.Type) -> String {
        StorageConcurrency.requireMainQueue()
        let request = T.fetchRequest()
        return "\((try? context.count(for: request)) ?? 0)" // try? ok: display count; an unreadable store shows zero
    }

    func countSources() -> String { countContent(for: AltSource.self) }
    func countSignedApps() -> String { countContent(for: Signed.self) }
    func countImportedApps() -> String { countContent(for: Imported.self) }
    func countCertificates() -> String { countContent(for: CertificatePair.self) }

    func clearSources() {
        guard persistentStorageUnavailableError == nil else { return }
        clearContext(request: AltSource.fetchRequest())
    }

    func clearSignedApps(removeDirectory: Bool = true) {
        guard persistentStorageUnavailableError == nil else {
            Logger.misc.fault("Refused clearing signed apps while persistent storage is unavailable.")
            return
        }
        let apps = fetchOnQueue(Signed.fetchRequest()).map { $0 as AppInfoPresentable }
        guard let leases = _libraryLeases(apps) else { return }
        defer { withExtendedLifetime(leases) {} }
        clearContext(request: Signed.fetchRequest())
        guard removeDirectory else { return }
        do {
            try FileManager.default.removeFileIfNeeded(at: FileManager.default.signed)
        } catch {
            Logger.misc.error("Failed to remove signed apps directory: \(LogRedaction.redact(error.localizedDescription), privacy: .public)")
        }
    }

    func clearImportedApps(removeDirectory: Bool = true) {
        guard persistentStorageUnavailableError == nil else {
            Logger.misc.fault("Refused clearing imported apps while persistent storage is unavailable.")
            return
        }
        let apps = fetchOnQueue(Imported.fetchRequest()).map { $0 as AppInfoPresentable }
        guard let leases = _libraryLeases(apps) else { return }
        defer { withExtendedLifetime(leases) {} }
        clearContext(request: Imported.fetchRequest())
        guard removeDirectory else { return }
        do {
            try FileManager.default.removeFileIfNeeded(at: FileManager.default.unsigned)
        } catch {
            Logger.misc.error("Failed to remove imported apps directory: \(LogRedaction.redact(error.localizedDescription), privacy: .public)")
        }
    }

    /// The same per-app leases `deleteApps` takes, for the paths that remove a whole
    /// library folder instead of one app.
    ///
    /// Without them a "clear signed apps" could delete `signed/` while a signing or
    /// install job was writing into it, which is the one thing the single-app path
    /// spends its quarantine dance to avoid. `nil` means an app is busy and nothing
    /// was removed.
    private func _libraryLeases(_ apps: [AppInfoPresentable]) -> [AppOperationRegistry.Lease]? {
        var leases: [AppOperationRegistry.Lease] = []
        do {
            for key in Set(apps.compactMap(AppOperationRegistry.key)) {
                leases.append(try AppOperationRegistry.shared.acquire(key))
            }
            return leases
        } catch {
            Toast.error(error.localizedDescription)
            return nil
        }
    }

    func clearCertificates(resetSelection: Bool = true, removeDirectory: Bool = true) {
        guard persistentStorageUnavailableError == nil else {
            Logger.misc.fault("Refused clearing certificates while persistent storage is unavailable.")
            return
        }
        if resetSelection {
            UserDefaults.standard.set(0, forKey: "vexsign.selectedCert")
        }
        clearContext(request: CertificatePair.fetchRequest())
        guard removeDirectory else { return }
        do {
            try FileManager.default.removeFileIfNeeded(at: FileManager.default.certificates)
        } catch {
            Logger.misc.error("Failed to remove certificates directory: \(LogRedaction.redact(error.localizedDescription), privacy: .public)")
        }
    }

	/// - Returns: why the legacy store could not be moved, when it could not be. The caller
	///   must not then open a fresh store at `VexSign.sqlite`, or the user's library reads as
	///   empty while their data still sits in `Feather.sqlite`.
	private static func _migrateLegacyStoreIfNeeded() -> Error? {
		let fm = FileManager.default
		guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
		let legacyBase = appSupport.appendingPathComponent("Feather.sqlite")
		let newBase = appSupport.appendingPathComponent("VexSign.sqlite")
		
		if fm.fileExists(atPath: newBase.path) { return nil }
		if !fm.fileExists(atPath: legacyBase.path) { return nil }
		
		let legacyFiles = [
			legacyBase,
			legacyBase.deletingPathExtension().appendingPathExtension("sqlite-wal"),
			legacyBase.deletingPathExtension().appendingPathExtension("sqlite-shm")
		]
		let newFiles = [
			newBase,
			newBase.deletingPathExtension().appendingPathExtension("sqlite-wal"),
			newBase.deletingPathExtension().appendingPathExtension("sqlite-shm")
		]
		
		// A pointer to the legacy store is only worth following if the store actually moves.
		//
		// This used to swallow every failure. When the move failed, `loadPersistentStores`
		// found nothing at `VexSign.sqlite` and created a *new, empty* store — so the user's
		// entire library (apps, certificates, sources) appeared to have been deleted, and the
		// old file sat beside it, unreferenced, until it was garbage-collected. Nothing was
		// reported, because the migration had "finished" without throwing.
		//
		// Now the base store either arrives or the failure is surfaced before the container is
		// loaded, so the recovery path in `_loadPersistentStoreAggressively` decides what to do
		// instead of a silent empty database.
		for (oldFile, newFile) in zip(legacyFiles, newFiles) {
			guard fm.fileExists(atPath: oldFile.path) else { continue }
			do {
				try fm.moveItem(at: oldFile, to: newFile)
			} catch {
				Logger.misc.fault(
					"Legacy library could not be migrated; refusing to open an empty store over it: \(LogRedaction.redact(error.localizedDescription), privacy: .public)"
				)
				return error
			}
		}
		return nil
	}

	/// True while the container is pointed at an unmigrated legacy store.
	///
	/// Legacy stores that failed migration stay untouched in place while error recovery
	/// quarantines unreadable stores without deleting app or certificate folders.
	private var _legacyStoreIsLive = false

    private func _loadPersistentStoreAggressively() {
        if _forcePersistentStoreFailure {
            let reason = "Forced persistent store load failure for recovery verification."
            let description = container.persistentStoreDescriptions.first
            let quarantined = _quarantineStore(at: description?.url, reason: reason)
            _mountUnavailableFallback(reason: reason, quarantineOutcome: quarantined)
            return
        }

        container.loadPersistentStores { description, error in
            if let error, self._legacyStoreIsLive {
                Logger.misc.fault(
                    "The legacy library could not be opened. It is left untouched so existing library data is preserved. \(LogRedaction.redact(error.localizedDescription), privacy: .public)"
                )
                self._mountUnavailableFallback(reason: error.localizedDescription, quarantineOutcome: nil)
                return
            }
            if let error {
                guard !self._inMemory else {
                    Logger.misc.fault("In-memory store failed to load: \(error.localizedDescription)")
                    return
                }
                Logger.misc.error(
                    "Core Data initial load failed: \(LogRedaction.redact(error.localizedDescription), privacy: .public); quarantining unreadable SQLite store"
                )
                guard let quarantined = self._quarantineStore(at: description.url, reason: error.localizedDescription) else {
                    self._mountUnavailableFallback(reason: error.localizedDescription, quarantineOutcome: nil)
                    return
                }
                self.container.loadPersistentStores { _, secondError in
                    if let secondError {
                        Logger.misc.fault(
                            "Core Data secondary load failed after store quarantine: \(LogRedaction.redact(secondError.localizedDescription), privacy: .public)"
                        )
                        self._mountUnavailableFallback(
                            reason: secondError.localizedDescription,
                            quarantineOutcome: quarantined
                        )
                    }
                }
            }
        }
    }

    private func _mountUnavailableFallback(
        reason: String,
        quarantineOutcome: CoreDataStoreRecovery.Outcome?
    ) {
        let redacted = LogRedaction.redact(reason)
        _availabilityLock.lock()
        _persistentStorageUnavailableState = true
        _persistentStorageUnavailableReasonState = redacted
        _availabilityLock.unlock()

        let folderName = quarantineOutcome?.notice.quarantineFolderName ?? "UnrecoveredStore"
        let notice = CoreDataStoreRecovery.Notice(
            quarantineFolderName: folderName,
            recoveredAt: quarantineOutcome?.notice.recoveredAt ?? Date(),
            summary: redacted,
            quarantineDirectory: quarantineOutcome?.quarantineDirectory,
            isPersistentStorageUnavailable: true
        )

        let publish = {
            self.isPersistentStorageUnavailable = true
            self.persistenceUnavailableReason = redacted
            self.quarantinedStoreDirectory = quarantineOutcome?.quarantineDirectory
            self.recoveryNotice = notice
        }
        if Thread.isMainThread {
            publish()
        } else {
            DispatchQueue.main.async(execute: publish)
        }

        // Mount an in-memory container only so the UI can surface the degraded-storage
        // warning and allow exporting diagnostics or quarantined stores. Every durable write
        // and destructive path checks `persistentStorageUnavailableError` and refuses mutation.
        let fallbackDescription = NSPersistentStoreDescription()
        fallbackDescription.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [fallbackDescription]
        container.loadPersistentStores { _, _ in }
    }

	// Backfills sortIndex from the old date-desc order so manual reordering starts stable
	private func _migrateSortIndexIfNeeded() {
		// A throwaway store has nothing to migrate, and the flag would otherwise be
		// written into the real UserDefaults by a test run.
		guard !_inMemory else { return }

		let key = "vexsign.sortIndexMigrated"
		guard !UserDefaults.standard.bool(forKey: key) else { return }

		// On the view context's own queue. `init` runs on whichever thread first
		// touches `Storage.shared`, and that can be a background thread - the
		// certificate importer starts its work from a utility queue during
		// launch. The view context belongs to the main queue, so a fetch from
		// the creating thread trips Core Data's multithreading assertion
		// (`_PFAssertSafeMultiThreadedAccess`): a SIGTRAP in a debug build and,
		// worse, an unsynchronised fetch in an optimised one.
		//
		// `performAndWait` hops to the context's queue and runs inline when it is
		// already there, so this is a no-op on the common path.
		let viewContext = container.viewContext
		viewContext.performAndWait {
			let signedRequest: NSFetchRequest<Signed> = Signed.fetchRequest()
			signedRequest.sortDescriptors = [NSSortDescriptor(keyPath: \Signed.date, ascending: false)]
			if let apps = try? viewContext.fetch(signedRequest) { // try? ok: best-effort sort-index backfill
				for (index, app) in apps.enumerated() { app.sortIndex = Int32(index) }
			}

			let importedRequest: NSFetchRequest<Imported> = Imported.fetchRequest()
			importedRequest.sortDescriptors = [NSSortDescriptor(keyPath: \Imported.date, ascending: false)]
			if let apps = try? viewContext.fetch(importedRequest) { // try? ok: best-effort sort-index backfill
				for (index, app) in apps.enumerated() { app.sortIndex = Int32(index) }
			}

			// Not `saveContext()`: that guard logs a fault, and the fetch above
			// already established the queue this work runs on.
			if viewContext.hasChanges {
				try? viewContext.save() // try? ok: best-effort sort-index persistence; see the comment above on avoiding saveContext's fault log
			}
		}
		UserDefaults.standard.set(true, forKey: key)
	}

    /// Dismisses the one-shot notice about a quarantined store when durable storage recovered.
    ///
    /// When persistent storage remains unavailable, the warning cannot be dismissed because
    /// write operations are disabled until storage recovers.
    func acknowledgeRecoveryNotice() {
        guard persistentStorageUnavailableError == nil else { return }
        recoveryNotice = nil
    }

    func quarantinedStores() -> [CoreDataStoreRecovery.QuarantinedStore] {
        let root: URL?
        if let custom = _customQuarantineRoot {
            root = custom
        } else if let directory = quarantinedStoreDirectory {
            root = directory.deletingLastPathComponent()
        } else if let storeURL = container.persistentStoreDescriptions.first?.url {
            root = CoreDataStoreRecovery.quarantineRoot(for: storeURL)
        } else if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            root = support.appendingPathComponent("QuarantinedStores", isDirectory: true)
        } else {
            root = nil
        }
        guard let root else { return [] }
        return CoreDataStoreRecovery.listQuarantinedStores(in: root)
    }

    @discardableResult
    private func _quarantineStore(at url: URL?, reason: String) -> CoreDataStoreRecovery.Outcome? {
        do {
            guard let outcome = try CoreDataStoreRecovery.quarantineStore(
                at: url,
                quarantineRoot: _customQuarantineRoot,
                reason: reason
            ) else {
                return nil
            }
            let notice = outcome.notice
            let publish = {
                self.recoveryNotice = notice
                self.quarantinedStoreDirectory = outcome.quarantineDirectory
            }
            if Thread.isMainThread {
                publish()
            } else {
                DispatchQueue.main.async(execute: publish)
            }
            Logger.misc.fault(
                "Quarantined unreadable Core Data store to \(notice.quarantineFolderName, privacy: .public); app and certificate files were preserved."
            )
            return outcome
        } catch {
            Logger.misc.fault(
                "Failed to quarantine unreadable Core Data store: \(LogRedaction.redact(error.localizedDescription), privacy: .public)"
            )
            return nil
        }
    }
}
