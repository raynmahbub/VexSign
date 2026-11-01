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
	static let shared = Storage()
	let container: NSPersistentContainer

	private let _name: String = "VexSign"
	private let _legacyName: String = "Feather" // For migration from old installs
	private let _inMemory: Bool
	/// Private-queue context owned by `write(_:)`. Created at the end of `init`
	/// and only ever touched from inside `perform`, which serialises writers.
	private var _writeContext: NSManagedObjectContext!

	init(inMemory: Bool = false) {
		self._inMemory = inMemory

		// Migrate legacy store file if exists (Feather.sqlite -> VexSign.sqlite) to preserve user data
		if !inMemory {
			Self._migrateLegacyStoreIfNeeded()
		}

		container = NSPersistentContainer(name: _name)

		if inMemory {
			// An in-memory description, not a SQLite store pointed at /dev/null:
			// the file-backed load path reports an error for that URL, and the
			// recovery below reacts to an error by deleting the store files.
			let description = NSPersistentStoreDescription()
			description.type = NSInMemoryStoreType
			container.persistentStoreDescriptions = [description]
		}

		_loadPersistentStoreAggressively()
		container.viewContext.automaticallyMergesChangesFromParent = true
		container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
		_migrateSortIndexIfNeeded()

		// One write context for the whole app: `perform` serialises on it, so a
		// read-modify-write (the sortIndex calculation) cannot interleave with
		// another write the way two independent background contexts could.
		let writeContext = container.newBackgroundContext()
		writeContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
		writeContext.automaticallyMergesChangesFromParent = true
		writeContext.undoManager = nil
		_writeContext = writeContext
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
		// Non-optional after `init`; the declaration is an IUO only because the
		// context needs the loaded container.
		let context = _writeContext!
		return try await withCheckedThrowingContinuation { continuation in
			context.perform {
				do {
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
		return (try? context.existingObject(with: id)) as? T
	}
	
	func saveContext() {
		StorageConcurrency.requireMainQueue()
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
	
	func clearContext<T: NSManagedObject>(request: NSFetchRequest<T>) {
		StorageConcurrency.requireMainQueue()
		let deleteRequest = NSBatchDeleteRequest(fetchRequest: (request as? NSFetchRequest<NSFetchRequestResult>)!)
		_ = try? context.execute(deleteRequest)
	}
	
	func countContent<T: NSManagedObject>(for type: T.Type) -> String {
		StorageConcurrency.requireMainQueue()
		let request = T.fetchRequest()
		return "\((try? context.count(for: request)) ?? 0)"
	}

	private static func _migrateLegacyStoreIfNeeded() {
		let fm = FileManager.default
		guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
		let legacyBase = appSupport.appendingPathComponent("Feather.sqlite")
		let newBase = appSupport.appendingPathComponent("VexSign.sqlite")
		
		if fm.fileExists(atPath: newBase.path) { return }
		if !fm.fileExists(atPath: legacyBase.path) { return }
		
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
		
		for (oldFile, newFile) in zip(legacyFiles, newFiles) {
			if fm.fileExists(atPath: oldFile.path) {
				try? fm.moveItem(at: oldFile, to: newFile)
			}
		}
	}

	private func _loadPersistentStoreAggressively() {
		container.loadPersistentStores { description, error in
			if let error {
				// Recovery deletes the store and the app's library folders; that is
				// the right call for a corrupt on-disk store and the wrong one for a
				// throwaway store in a test host.
				guard !self._inMemory else {
					Logger.misc.fault("In-memory store failed to load: \(error.localizedDescription)")
					return
				}
				Logger.misc.error("Core Data initial load failed: \(error.localizedDescription), attempting recovery via store reset")
				self._destroyStore(at: description.url)
				self.container.loadPersistentStores { _, secondError in
					if let secondError {
						Logger.misc.fault("Core Data secondary load failed after store reset: \(secondError.localizedDescription)")
						// Fallback gracefully without crashing the app: use an in-memory description
						let fallbackDescription = NSPersistentStoreDescription()
						fallbackDescription.type = NSInMemoryStoreType
						self.container.persistentStoreDescriptions = [fallbackDescription]
						self.container.loadPersistentStores { _, _ in }
					}
				}
			}
		}
	}

	// Backfills sortIndex from the old date-desc order so manual reordering starts stable
	private func _migrateSortIndexIfNeeded() {
		// A throwaway store has nothing to migrate, and the flag would otherwise be
		// written into the real UserDefaults by a test run.
		guard !_inMemory else { return }

		let key = "vexsign.sortIndexMigrated"
		guard !UserDefaults.standard.bool(forKey: key) else { return }

		let signedRequest: NSFetchRequest<Signed> = Signed.fetchRequest()
		signedRequest.sortDescriptors = [NSSortDescriptor(keyPath: \Signed.date, ascending: false)]
		if let apps = try? context.fetch(signedRequest) {
			for (index, app) in apps.enumerated() { app.sortIndex = Int32(index) }
		}

		let importedRequest: NSFetchRequest<Imported> = Imported.fetchRequest()
		importedRequest.sortDescriptors = [NSSortDescriptor(keyPath: \Imported.date, ascending: false)]
		if let apps = try? context.fetch(importedRequest) {
			for (index, app) in apps.enumerated() { app.sortIndex = Int32(index) }
		}

		// Not `saveContext()`: this runs inside `init`, on whichever thread
		// created the store, before any other code can hold a reference. The
		// main-queue guard on `saveContext` would log a fault for a lifecycle
		// that is single-threaded by construction.
		if container.viewContext.hasChanges {
			try? container.viewContext.save()
		}
		UserDefaults.standard.set(true, forKey: key)
	}

	private func _destroyStore(at url: URL?) {
		guard let url else { return }

		let base = url.deletingPathExtension()
		let fm = FileManager.default

		let files = [
			base.appendingPathExtension("sqlite"),
			base.appendingPathExtension("sqlite-wal"),
			base.appendingPathExtension("sqlite-shm")
		]

		for file in files {
			try? fm.removeItem(at: file)
		}

		try? FileManager.default.removeFileIfNeeded(at: FileManager.default.signed)
		try? FileManager.default.removeFileIfNeeded(at: FileManager.default.unsigned)
		try? FileManager.default.removeFileIfNeeded(at: FileManager.default.certificates)
		UserDefaults.standard.set(0, forKey: "vexsign.selectedCert")
	}
}
