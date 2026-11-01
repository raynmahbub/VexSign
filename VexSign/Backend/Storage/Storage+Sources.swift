//
//  Storage+Sources.swift
//  VexSign
//
//  Created by VexSign TeamSign Team on 12.04.2025.
//

import CoreData
import AltSourceKit
import OSLog

// MARK: - Class extension: Sources
extension Storage {
	/// Retrieve sources in an array, we don't normally need this in swiftUI but we have it for the copy sources action
	func getSources() -> [AltSource] {
		let request: NSFetchRequest<AltSource> = AltSource.fetchRequest()
		return (try? context.fetch(request)) ?? []
	}
	
	func addSource(
		_ url: URL,
		name: String? = "Unknown",
		identifier: String,
		iconURL: URL? = nil,
		deferSave: Bool = false,
		enforceTransportPolicy: Bool = true,
		completion: @escaping (Error?) -> Void
	) {
		StorageConcurrency.requireMainQueue()
		if sourceExists(identifier) {
			completion(nil)
			Logger.misc.debug("ignoring \(identifier)")
			return
		}

		// Transport policy: a repository must be served over HTTPS unless the
		// user explicitly opted into insecure HTTP (e.g. a LAN repository).
		// Backup restore passes `enforceTransportPolicy: false` to keep
		// restoring the user's own previously-saved configuration.
		if enforceTransportPolicy {
			do {
				try SourceURLPolicy.validate(url)
			} catch {
				Logger.security.warning("Rejected repository with insecure transport: \(url.absoluteString, privacy: .public)")
				completion(error)
				return
			}
		}
		
		let new = AltSource(context: context)
		new.name = name
		new.date = Date()
		new.identifier = identifier
		new.sourceURL = url
		new.iconURL = iconURL
		
		do {
			if !deferSave {
				try context.save()
                Task { await AnalyticsStore.shared.record(.repositoriesAdded) }
                Task { @MainActor in Haptics.lightImpact() }
			}
			completion(nil)
		} catch {
			completion(error)
		}
	}
	
	func addSource(
		_ url: URL,
		repository: ASRepository,
		id: String = "",
		deferSave: Bool = false,
		enforceTransportPolicy: Bool = true,
		completion: @escaping (Error?) -> Void
	) {
		addSource(
			url,
			name: repository.name,
			identifier: !id.isEmpty
					? id
					: (repository.id ?? url.absoluteString),
			iconURL: repository.currentIconURL,
			deferSave: deferSave,
			enforceTransportPolicy: enforceTransportPolicy,
			completion: completion
		)
	}

	func addSources(
		repos: [URL: ASRepository],
		completion: @escaping (Error?) -> Void
	) {
		StorageConcurrency.requireMainQueue()
		for (url, repo) in repos {
			addSource(
				url,
				repository: repo,
				deferSave: true,
				completion: { error in
					if let error {
						completion(error)
					}
				}
			)
		}
		
		saveContext()
		Task { @MainActor in Haptics.lightImpact() }
		completion(nil)
	}

	func deleteSource(for source: AltSource) {
		StorageConcurrency.requireMainQueue()
		if let url = source.sourceURL {
			let remainingURLs = getSources()
				.filter { $0 != source }
				.compactMap { $0.sourceURL }
			VexSignAPI.unregisterPremiumSourceIfNeeded(url, remainingSourceURLs: remainingURLs)
		}
		context.delete(source)
		saveContext()
	}

	func sourceExists(_ identifier: String) -> Bool {
		let fetchRequest: NSFetchRequest<AltSource> = AltSource.fetchRequest()
		fetchRequest.predicate = NSPredicate(format: "identifier == %@", identifier)

		do {
			let count = try context.count(for: fetchRequest)
			return count > 0
		} catch {
			Logger.misc.error("Error checking if repository exists: \(error)")
			return false
		}
	}
}
