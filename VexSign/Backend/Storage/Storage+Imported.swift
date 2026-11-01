//
//  Storage+Imported.swift
//  VexSign
//
//  Created by VexSign TeamSign Team on 11.04.2025.
//

import CoreData

// MARK: - Class extension: Imported Apps
extension Storage {
	/// Inserts an imported-app row from a detached task and returns its object ID.
	///
	/// Runs on the write context (see `write(_:)`); resolve the result with
	/// `object(_:)` on the main actor, or look it up by `uuid`.
	@discardableResult
	func addImported(
		uuid: String,
		source: URL? = nil,

		appName: String? = nil,
		appIdentifier: String? = nil,
		appVersion: String? = nil,
		appIcon: String? = nil,
		appDescription: String? = nil
	) async throws -> NSManagedObjectID {
		let id = try await write { context in
			let new = Imported(context: context)

			new.uuid = uuid
			new.source = source
			new.date = Date()
			new.sortIndex = nextImportedSortIndex(in: context)

			new.originalIdentifier = appIdentifier
			new.identifier = appIdentifier

			new.name = appName
			new.icon = appIcon
			new.version = appVersion
			new.appDescription = appDescription

			return new
		}

		Task { @MainActor in WidgetStatusPublisher.publish() }
		return id
	}

	/// Below the current lowest so new apps land at the top.
	/// Must run on the context that is doing the insert.
	func nextImportedSortIndex(in context: NSManagedObjectContext) -> Int32 {
		let request: NSFetchRequest<Imported> = Imported.fetchRequest()
		request.sortDescriptors = [NSSortDescriptor(key: "sortIndex", ascending: true)]
		request.fetchLimit = 1

		let lowest = (try? context.fetch(request))?.first?.sortIndex ?? 1
		return lowest - 1
	}
}
