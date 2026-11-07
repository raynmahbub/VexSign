//
//  Storage+Shared.swift
//  VexSign
//
//  Created by VexSign TeamSign Team on 17.04.2025.
//

import CoreData
import OSLog
import SwiftUI

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

	/// One save for the whole batch: saving per item mid-edit blows up the SwiftUI list diff.
	///
	/// Everything that can go wrong here used to go wrong silently — a file that would not be
	/// removed was swallowed by `try?`, and a save that failed only reached the unified log — so
	/// "Delete does nothing" had no visible cause. The save is checked now and the result is
	/// reported back; the file removal is logged, and never stops the row from going away.
	///
	/// - Returns: false when at least one row could not be deleted.
	@discardableResult
	func deleteApps(_ apps: [AppInfoPresentable]) -> Bool {
		StorageConcurrency.requireMainQueue()
		guard !apps.isEmpty else { return true }

		var deletedAny = false
		for app in apps {
			if let url = getUuidDirectory(for: app) {
				do {
					try FileManager.default.removeItem(at: url)
				} catch {
					// A directory that is already gone is not a problem: the row is what matters.
					if FileManager.default.fileExists(atPath: url.path) {
						Logger.misc.error("Could not remove \(url.path): \(error.localizedDescription)")
					}
				}
			}
			// A caller may hand over a row from another context (the storage screen and the
			// automation paths fetch off the main queue); `delete` on a foreign object is a
			// no-op at best, so it is resolved here first.
			guard let object = _deletableRow(for: app) else { continue }
			context.delete(object)
			deletedAny = true
		}

		guard deletedAny else { return false }
		guard context.hasChanges else { return true }

		do {
			try context.save()
		} catch {
			Logger.misc.error("CoreData save failed while deleting apps: \(error.localizedDescription)")
			return false
		}

		Task { @MainActor in WidgetStatusPublisher.publish() }
		return true
	}

	/// The same row, but owned by the main-queue context.
	private func _deletableRow(for app: AppInfoPresentable) -> NSManagedObject? {
		guard let object = app as? NSManagedObject, !object.isDeleted else { return nil }
		if object.managedObjectContext === context { return object }

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
