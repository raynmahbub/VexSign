//
//  Storage+Shared.swift
//  VexSign
//
//  Created by VexSign TeamSign Team on 17.04.2025.
//

import CoreData
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
	
	func deleteApp(for app: AppInfoPresentable) {
		StorageConcurrency.requireMainQueue()
		deleteApps([app])
	}

	/// One save for the whole batch: saving per item mid-edit blows up the SwiftUI list diff.
	func deleteApps(_ apps: [AppInfoPresentable]) {
		StorageConcurrency.requireMainQueue()
		guard !apps.isEmpty else { return }

		for app in apps {
			if let url = getUuidDirectory(for: app) {
				try? FileManager.default.removeItem(at: url)
			}
			if let object = app as? NSManagedObject {
				context.delete(object)
			}
		}

		saveContext()
		Task { @MainActor in WidgetStatusPublisher.publish() }
	}
	
	func getCertificate(from app: AppInfoPresentable) -> CertificatePair? {
		if let signed = app as? Signed {
			return signed.certificate
		}
		return nil
	}

	func getAllApps() -> [AppInfoPresentable] {
		let signed = (try? context.fetch(Signed.fetchRequest())) ?? []
		let imported = (try? context.fetch(Imported.fetchRequest())) ?? []
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
