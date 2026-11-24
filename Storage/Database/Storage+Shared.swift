//
//  Storage+Shared.swift
//  VexSign
//
//  Created by VexSign Contributors on 17.04.2025.
//

import CoreData
import OSLog
import NimbleExtensions

struct AppDeletionOutcome {
    let committed: Bool
    let freedBytes: Int64
}

// MARK: - Class extension: Apps (Shared)
extension Storage {
	func getUuidDirectory(for app: AppInfoPresentable) -> URL? {
		guard let uuid = app.uuid else { return nil }
		return app.isSigned
		? FileManager.default.signed(uuid)
		: FileManager.default.unsigned(uuid)
	}
	
	func getAppDirectory(for app: AppInfoPresentable) -> URL? {
		guard let url = getUuidDirectory(for: app) else { return nil }
		return FileManager.default.getPath(in: url, for: "app")
	}
	
	/// - Returns: false when the row survives the delete, so a caller can say so instead of
	///   leaving the user with a tap that did nothing.
	@discardableResult
	func deleteApp(for app: AppInfoPresentable) -> Bool {
		StorageConcurrency.requireMainQueue()
		return deleteApps([app])
	}

    /// Quarantine first, commit deletion in an isolated context, then purge.
    /// Save failures cannot roll back unrelated edits in the view context.
    /// Post-commit cleanup failure is tracked and retried at launch.

	@discardableResult
	func deleteApps(_ apps: [AppInfoPresentable],
                    saveDeletion: (NSManagedObjectContext) throws -> Void = { try $0.save() }) -> Bool {
        deleteAppsWithOutcome(apps, saveDeletion: saveDeletion).committed
    }

    func deleteAppsWithOutcome(_ apps: [AppInfoPresentable],
                    saveDeletion: (NSManagedObjectContext) throws -> Void = { try $0.save() }) -> AppDeletionOutcome {
		StorageConcurrency.requireMainQueue()
		guard !apps.isEmpty else { return AppDeletionOutcome(committed: true, freedBytes: 0) }
        let resolved = apps.compactMap { _deletableRow(for: $0) }
        let ids = Array(Set(resolved.map(\.objectID)))
        guard resolved.count == apps.count, ids.count == apps.count, !ids.isEmpty,
              ids.allSatisfy({ !$0.isTemporaryID }),
              Set(ids.compactMap { $0.persistentStore?.identifier }).count == 1 else { return AppDeletionOutcome(committed: false, freedBytes: 0) }
        let managedApps = resolved.compactMap { $0 as? AppInfoPresentable }
        guard managedApps.count == resolved.count else { return AppDeletionOutcome(committed: false, freedBytes: 0) }
        var leases: [AppOperationRegistry.Lease] = []
        do {
            for key in Set(managedApps.compactMap(AppOperationRegistry.key)) {
                leases.append(try AppOperationRegistry.shared.acquire(key))
            }
        } catch {
            Toast.error(error.localizedDescription)
            return AppDeletionOutcome(committed: false, freedBytes: 0)
        }
        defer { withExtendedLifetime(leases) {} }

        // Resolve all rows before moving anything. A sibling context makes save
        // failure rollback local to this deletion, not unrelated UI edits.
        let deletion = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        deletion.persistentStoreCoordinator = container.persistentStoreCoordinator
        deletion.mergePolicy = NSErrorMergePolicy
        var transaction: StagedAppDeletion?
        var originalSizes: [Int64] = []
        do {
            let rows = try ids.map { id -> NSManagedObject in
                guard let entity = id.entity.name else { throw CocoaError(.fileReadCorruptFile) }
                let fetch = NSFetchRequest<NSManagedObject>(entityName: entity)
                fetch.predicate = NSPredicate(format: "SELF == %@", id)
                fetch.fetchLimit = 1
                guard let row = try deletion.fetch(fetch).first else { throw CocoaError(.fileNoSuchFile) }
                return row
            }
            let originals = try rows.map { row -> (URL, URL) in
                guard let app = row as? AppInfoPresentable, let directory = getUuidDirectory(for: app),
                      Self._allowedDeletionOriginal(directory) else { throw CocoaError(.fileReadCorruptFile) }
                // A directory must belong to exactly one committed record of
                // this kind. A corrupt duplicate UUID must not erase a sibling version.
                guard let entityName = row.entity.name, let uuid = app.uuid else { throw CocoaError(.fileReadCorruptFile) }
                let owners = NSFetchRequest<NSFetchRequestResult>(entityName: entityName)
                owners.predicate = NSPredicate(format: "uuid ==[c] %@", uuid)
                owners.includesPendingChanges = false
                guard try deletion.count(for: owners) == 1 else { throw CocoaError(.fileReadCorruptFile) }
                return (directory, row.objectID.uriRepresentation())
            }
            originalSizes = originals.map { CleanupRemovalPolicy.allocatedSizeWithoutFollowingSymlinks(at: $0.0) }
            let deletionRoot = try Self._prepareDeletionRoot()
            let staged = try StagedAppDeletion(root: deletionRoot, originals: originals)
            guard CleanupRemovalPolicy.isSafeDirectory(staged.directory, beneath: deletionRoot) else {
                throw CleanupRemovalPolicy.Rejection.unsafeTarget
            }
            transaction = staged
            try staged.stage()
            for row in rows { deletion.delete(row) }
            try saveDeletion(deletion)
        } catch {
            deletion.rollback()
            if let transaction {
                do { try transaction.recover(rowExists: _deletionRowExists, allowedOriginal: Self._allowedDeletionOriginal) }
                catch { Logger.misc.error("Deletion rollback deferred; recovery files retained.") }
            }
            Toast.error(String.localized("Deletion could not be completed. Your app records were kept; recovery files, if any, are retained."))
            return AppDeletionOutcome(committed: false, freedBytes: 0)
        }
        NSManagedObjectContext.mergeChanges(fromRemoteContextSave: [NSDeletedObjectsKey: ids], into: [context])
        var freedBytes: Int64 = 0
        if let transaction {
            do { try transaction.recover(rowExists: { _ in false }, allowedOriginal: Self._allowedDeletionOriginal) }
            catch { Logger.misc.warning("Deleted app cleanup deferred; tracked quarantine retained.") }
            for (index, entry) in transaction.entries.enumerated() where index < originalSizes.count {
                let staged = transaction.directory.appendingPathComponent(entry.slot)
                if Self._isAbsentWithoutSymlink(staged) { freedBytes += originalSizes[index] }
            }
        }

		Task { @MainActor in WidgetStatusPublisher.publish() }
		return AppDeletionOutcome(committed: true, freedBytes: freedBytes)
	}

    private static func _isAbsentWithoutSymlink(_ url: URL) -> Bool {
        do {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { return false }
            return !FileManager.default.fileExists(atPath: url.path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return true
        } catch {
            return false
        }
    }

    private static var _applicationSupportRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    private static var _deletionRoot: URL {
        _applicationSupportRoot.appendingPathComponent("PendingAppDeletions", isDirectory: true)
    }

    private static func _prepareDeletionRoot() throws -> URL {
        let fileManager = FileManager.default
        let library = fileManager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let support = _applicationSupportRoot
        if !fileManager.fileExists(atPath: support.path) {
            try fileManager.createDirectory(at: support, withIntermediateDirectories: true)
        }
        guard CleanupRemovalPolicy.isSafeDirectory(support, beneath: library) else {
            throw CleanupRemovalPolicy.Rejection.unsafeTarget
        }
        if !fileManager.fileExists(atPath: _deletionRoot.path) {
            try fileManager.createDirectory(at: _deletionRoot, withIntermediateDirectories: false)
        }
        guard CleanupRemovalPolicy.isSafeDirectory(_deletionRoot, beneath: support) else {
            throw CleanupRemovalPolicy.Rejection.unsafeTarget
        }
        return _deletionRoot
    }

    private static func _allowedDeletionOriginal(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        let path = url.standardizedFileURL
        let roots = [fileManager.signed, fileManager.unsigned]
        guard path.isFileURL, UUID(uuidString: path.lastPathComponent) != nil,
              !url.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              let root = roots.first(where: { $0.standardizedFileURL.path == path.deletingLastPathComponent().path }),
              CleanupRemovalPolicy.isSafeDirectory(root, beneath: URL.documentsDirectory) else { return false }

        do {
            let values = try path.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { return false }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // A missing bundle may still have a stale library row; the row can be deleted without
            // authorizing any filesystem removal outside the verified storage root.
            return true
        } catch {
            return false
        }
        return CleanupRemovalPolicy.isSafeTarget(path, beneath: root)
    }

    private func _deletionRowExists(_ uri: URL) throws -> Bool {
        guard let id = container.persistentStoreCoordinator.managedObjectID(forURIRepresentation: uri),
              let entity = id.entity.name else { throw CocoaError(.fileReadCorruptFile) }
        let reader = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        reader.persistentStoreCoordinator = container.persistentStoreCoordinator
        let request = NSFetchRequest<NSFetchRequestResult>(entityName: entity)
        request.predicate = NSPredicate(format: "SELF == %@", id)
        request.includesPendingChanges = false
        return try reader.count(for: request) > 0
    }

    /// Run after the persistent store loads and before automatic cleanup. Failed
    /// or protected/unreadable transactions remain on disk for the next launch.
    func recoverPendingAppDeletions() {
        StorageConcurrency.requireMainQueue()
        // Recovery is destructive cleanup too. If signing/import/installation
        // already owns an artifact, retain the journal rather than racing it.
        guard let recoveryLease = AppOperationRegistry.shared.acquireCleanup() else { return }
        defer { withExtendedLifetime(recoveryLease) {} }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: Self._deletionRoot.path) else { return }
        let library = fileManager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        guard CleanupRemovalPolicy.isSafeDirectory(Self._applicationSupportRoot, beneath: library),
              CleanupRemovalPolicy.isSafeDirectory(Self._deletionRoot, beneath: Self._applicationSupportRoot) else {
            Logger.misc.warning("Pending app deletion journal path is unsafe; no files changed.")
            return
        }
        do {
            let directories = try fileManager.contentsOfDirectory(at: Self._deletionRoot, includingPropertiesForKeys: nil)
            for directory in directories {
                guard CleanupRemovalPolicy.isSafeDirectory(directory, beneath: Self._deletionRoot) else {
                    Logger.misc.warning("Unsafe pending app deletion entry retained.")
                    continue
                }
                do {
                    let transaction = try StagedAppDeletion(directory: directory)
                    try transaction.recover(rowExists: _deletionRowExists, allowedOriginal: Self._allowedDeletionOriginal)
                } catch { Logger.misc.warning("Pending app deletion recovery deferred; files retained.") }
            }
        } catch { Logger.misc.warning("Pending app deletion journal is unavailable; no files changed.") }
    }

	/// The same row, but owned by the main-queue context.
	private func _deletableRow(for app: AppInfoPresentable) -> NSManagedObject? {
        do {
            let managed = try managedApp(matching: LibraryAppReference(app: app))
            guard let object = managed as? NSManagedObject, object.managedObjectContext === context, !object.isDeleted else {
                Logger.misc.error("Deletion refused for a stale or foreign library row.")
                return nil
            }
            return object
        } catch {
            Logger.misc.error("Could not resolve the selected library row for deletion.")
            return nil
        }
	}

	func getCertificate(from app: AppInfoPresentable) -> CertificatePair? {
		if let reference = try? LibraryAppReference(app: app), // try? ok: optional certificate lookup fails closed for a bad identity
           let signed = (try? managedApp(matching: reference)) as? Signed { // try? ok: unsigned/stale/foreign records have no linked certificate
			return signed.certificate
		}
		return nil
	}

	func getAllApps() -> [AppInfoPresentable] {
		let signed = fetchOnQueue(Signed.fetchRequest())
		let imported = fetchOnQueue(Imported.fetchRequest())
		return signed.map { $0 as AppInfoPresentable } + imported.map { $0 as AppInfoPresentable }
	}

    /// Immutable arrays for update matching outside a SwiftUI environment.
    @MainActor
    func getSignedApps() -> [LibraryAppRecord] {
        let adapter = CoreDataWorkspaceRepository(storage: self)
        do { return try context.fetch(Signed.fetchRequest()).map { try adapter.appRecord($0) } }
        catch { Logger.misc.error("Could not read a store-bound signed-app snapshot."); return [] }
    }

    @MainActor
    func getImportedApps() -> [LibraryAppRecord] {
        let adapter = CoreDataWorkspaceRepository(storage: self)
        do { return try context.fetch(Imported.fetchRequest()).map { try adapter.appRecord($0) } }
        catch { Logger.misc.error("Could not read a store-bound imported-app snapshot."); return [] }
    }

	func app(withUuid uuid: String) -> AppInfoPresentable? {
		getAllApps().first { $0.uuid == uuid }
	}

	func updateDescription(for app: AppInfoPresentable, description: String?) {
        StorageConcurrency.requireMainQueue()
        do {
            let row = try managedApp(matching: LibraryAppReference(app: app))
            if let imported = row as? Imported { imported.appDescription = description }
            else if let signed = row as? Signed { signed.appDescription = description }
            else { throw WorkspaceAccessError.invalidReference }
            saveContext()
        } catch { Logger.misc.error("Library metadata edit refused for an unavailable record.") }
	}

	func updateAppName(for app: AppInfoPresentable, name: String) {
        StorageConcurrency.requireMainQueue()
        do {
            let row = try managedApp(matching: LibraryAppReference(app: app))
            if let imported = row as? Imported { imported.name = name }
            else if let signed = row as? Signed { signed.name = name }
            else { throw WorkspaceAccessError.invalidReference }
            saveContext()
        } catch { Logger.misc.error("Library metadata edit refused for an unavailable record.") }
	}

	func updateAppName(uuid: String, newName: String) {
		if let target = app(withUuid: uuid) {
			updateAppName(for: target, name: newName)
		}
	}
}

// Managed records stay inside the persistence adapter.
extension Signed: AppInfoPresentable {
    var isSigned: Bool { true }
    var recordID: String? { objectID.uriRepresentation().absoluteString }
    var bundleURL: URL? { Storage.shared.getAppDirectory(for: self) }
    var artifactURL: URL? { Storage.shared.getUuidDirectory(for: self) }
}

extension Imported: AppInfoPresentable {
    var isSigned: Bool { false }
    var recordID: String? { objectID.uriRepresentation().absoluteString }
    var bundleURL: URL? { Storage.shared.getAppDirectory(for: self) }
    var artifactURL: URL? { Storage.shared.getUuidDirectory(for: self) }
}
