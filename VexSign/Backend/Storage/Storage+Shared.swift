//
//  Storage+Shared.swift
//  VexSign
//
//  Created by VexSign TeamSign Team on 17.04.2025.
//

import CoreData
import OSLog
import SwiftUI
import NimbleExtensions

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
		StorageConcurrency.requireMainQueue()
		guard !apps.isEmpty else { return true }
        let resolved = apps.compactMap { _deletableRow(for: $0) }
        let ids = Array(Set(resolved.map(\.objectID)))
        guard resolved.count == apps.count, !ids.isEmpty,
              ids.allSatisfy({ !$0.isTemporaryID }),
              Set(ids.compactMap { $0.persistentStore?.identifier }).count == 1 else { return false }
        let managedApps = resolved.compactMap { $0 as? AppInfoPresentable }
        guard managedApps.count == resolved.count else { return false }
        var leases: [AppOperationRegistry.Lease] = []
        do {
            for key in Set(managedApps.compactMap(AppOperationRegistry.key)) {
                leases.append(try await AppOperationRegistry.shared.acquire(key))
            }
        } catch {
            Toast.error(error.localizedDescription)
            return false
        }
        defer { withExtendedLifetime(leases) {} }

        // Resolve all rows before moving anything. A sibling context makes save
        // failure rollback local to this deletion, not unrelated UI edits.
        let deletion = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        deletion.persistentStoreCoordinator = container.persistentStoreCoordinator
        deletion.mergePolicy = NSErrorMergePolicy
        var transaction: StagedAppDeletion?
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
                return (directory, row.objectID.uriRepresentation())
            }
            let staged = try StagedAppDeletion(root: Self._deletionRoot, originals: originals)
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
            return false
        }
        NSManagedObjectContext.mergeChanges(fromRemoteContextSave: [NSDeletedObjectsKey: ids], into: [context])
        if let transaction {
            do { try transaction.recover(rowExists: { _ in false }, allowedOriginal: Self._allowedDeletionOriginal) }
            catch { Logger.misc.warning("Deleted app cleanup deferred; tracked quarantine retained.") }
        }

		Task { @MainActor in WidgetStatusPublisher.publish() }
		return true
	}

    private static var _deletionRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PendingAppDeletions", isDirectory: true)
    }

    private static func _allowedDeletionOriginal(_ url: URL) -> Bool {
        let path = url.standardizedFileURL
        guard path.isFileURL, !path.lastPathComponent.isEmpty,
              !url.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { return false }
        let parent = path.deletingLastPathComponent().resolvingSymlinksInPath()
        return [FileManager.default.signed, FileManager.default.unsigned].contains {
            $0.resolvingSymlinksInPath() == parent
        }
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
        guard FileManager.default.fileExists(atPath: Self._deletionRoot.path) else { return }
        do {
            let directories = try FileManager.default.contentsOfDirectory(at: Self._deletionRoot, includingPropertiesForKeys: nil)
            for directory in directories {
                do {
                    let transaction = try StagedAppDeletion(directory: directory)
                    try transaction.recover(rowExists: _deletionRowExists, allowedOriginal: Self._allowedDeletionOriginal)
                } catch { Logger.misc.warning("Pending app deletion recovery deferred; files retained.") }
            }
        } catch { Logger.misc.warning("Pending app deletion journal is unavailable; no files changed.") }
    }

	/// The same row, but owned by the main-queue context.
	private func _deletableRow(for app: AppInfoPresentable) -> NSManagedObject? {
		guard let object = app as? NSManagedObject else { return nil }
		if object.managedObjectContext === context { return object.isDeleted ? nil : object }

		var resolved: NSManagedObject?
		context.performAndWait {
			do {
				let existing = try context.existingObject(with: object.objectID)
				resolved = existing.isDeleted ? nil : existing
			} catch {
				Logger.misc.error("Could not resolve a row for deletion: \(error.localizedDescription)")
			}
		}
		return resolved
	}
	
	func getCertificate(from app: AppInfoPresentable) -> CertificatePair? {
		if let signed = app as? Signed {
			return signed.certificate
		}
		return nil
	}

	func getAllApps() -> [AppInfoPresentable] {
		let signed = fetchOnQueue(Signed.fetchRequest())
		let imported = fetchOnQueue(Imported.fetchRequest())
		return signed.map { $0 as AppInfoPresentable } + imported.map { $0 as AppInfoPresentable }
	}

	/// Fetched results helpers for callers that pass them into `AppUpdateChecker`.
	/// `FetchRequest` backs the same on-demand `FetchedResults` the SwiftUI views get, so the
	/// automation paths can use the checker without owning a `@FetchRequest`.
	func getSignedApps() -> FetchedResults<Signed> {
		let fetchRequest = Signed.fetchRequest()
		fetchRequest.sortDescriptors = []
		return FetchRequest(fetchRequest: fetchRequest).wrappedValue
	}

	func getImportedApps() -> FetchedResults<Imported> {
		let fetchRequest = Imported.fetchRequest()
		fetchRequest.sortDescriptors = []
		return FetchRequest(fetchRequest: fetchRequest).wrappedValue
	}

	func app(withUuid uuid: String) -> AppInfoPresentable? {
		getAllApps().first { $0.uuid == uuid }
	}

	func updateDescription(for app: AppInfoPresentable, description: String?) {
		StorageConcurrency.requireMainQueue()
		if let imported = app as? Imported {
			imported.appDescription = description
			saveContext()
		} else if let signed = app as? Signed {
			signed.appDescription = description
			saveContext()
		}
	}

	func updateAppName(for app: AppInfoPresentable, name: String) {
		StorageConcurrency.requireMainQueue()
		if let imported = app as? Imported {
			imported.name = name
			saveContext()
		} else if let signed = app as? Signed {
			signed.name = name
			saveContext()
		}
	}

	func updateAppName(uuid: String, newName: String) {
		if let target = app(withUuid: uuid) {
			updateAppName(for: target, name: newName)
		}
	}
}

// MARK: - Helpers
struct AnyApp: Identifiable {
	let base: AppInfoPresentable
	var archive: Bool = false
    var installAfterSigning: Bool = false
	
	var id: String {
		base.uuid ?? UUID().uuidString
	}
}

protocol AppInfoPresentable {
	var name: String? { get }
	var version: String? { get }
	var identifier: String? { get }
	var originalIdentifier: String? { get }
	var date: Date? { get }
	var icon: String? { get }
	var uuid: String? { get }
	var isSigned: Bool { get }
	var appDescription: String? { get set }
}

extension Signed: AppInfoPresentable {
	var isSigned: Bool { true }
}

extension Imported: AppInfoPresentable {
	var isSigned: Bool { false }
}
