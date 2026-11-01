//
//  Storage+Signed.swift
//  VexSign
//
//  Created by VexSign TeamSign Team on 17.04.2025.
//

import CoreData

// MARK: - Class extension: Signed Apps
extension Storage {
	/// Inserts a signed-app row from a detached task and returns its object ID.
	///
	/// Runs on the write context (see `write(_:)`), so nothing here may use a
	/// managed object that came from the view context - `certificateID` is the
	/// ID of the certificate row, not the object. Resolve the result with
	/// `object(_:)` on the main actor, or look it up by `uuid`.
	@discardableResult
	func addSigned(
		uuid: String,
		source: URL? = nil,
		certificateID: NSManagedObjectID? = nil,

		appName: String? = nil,
		appIdentifier: String? = nil,
		originalAppIdentifier: String? = nil,
		appVersion: String? = nil,
		appIcon: String? = nil,
		appDescription: String? = nil
	) async throws -> NSManagedObjectID {
		let id = try await write { context in
			let new = Signed(context: context)

			new.uuid = uuid
			new.source = source
			new.date = Date()
			new.sortIndex = self.nextSignedSortIndex(in: context)

			if let certificateID {
				// Re-fetch on the write context: the caller's instance belongs to
				// the view context and must not cross queues.
				new.certificate = try context.existingObject(with: certificateID) as? CertificatePair
			}

			// Identifier before PPQ protection / modifications
			new.originalIdentifier = originalAppIdentifier ?? appIdentifier
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
	func nextSignedSortIndex(in context: NSManagedObjectContext) -> Int32 {
		let request: NSFetchRequest<Signed> = Signed.fetchRequest()
		request.sortDescriptors = [NSSortDescriptor(key: "sortIndex", ascending: true)]
		request.fetchLimit = 1

		let lowest = (try? context.fetch(request))?.first?.sortIndex ?? 1
		return lowest - 1
	}
}
