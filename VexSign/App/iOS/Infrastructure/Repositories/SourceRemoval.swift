import Foundation
import NimbleExtensions

// MARK: - Sources

/// Removes a repository while keeping what is needed to add it back.
enum SourceRemoval {
	struct Snapshot: Equatable {
		let url: URL
		let name: String?
		let identifier: String
		let iconURL: URL?
		let date: Date?
	}

	static func snapshot(of source: AltSource) -> Snapshot? {
		guard let url = source.sourceURL, let identifier = source.identifier else { return nil }
		return Snapshot(url: url, name: source.name, identifier: identifier, iconURL: source.iconURL, date: source.date)
	}

	/// Deletes sources and offers Undo for those that can be restored exactly. Premium
	/// sources are deleted without Undo: removing one also unregisters it, which adding the
	/// row back would not reverse.
	static func delete(_ sources: [AltSource]) {
		var snapshots: [Snapshot] = []
		for source in sources {
			if let snapshot = snapshot(of: source), !VexSignAPI.isPremiumSource(snapshot.url) {
				snapshots.append(snapshot)
			}
			Storage.shared.deleteSource(for: source)
		}
		guard let first = snapshots.first else { return }

		let title = snapshots.count == 1
			? (first.name ?? first.url.host ?? first.url.absoluteString)
			: String.localized("%lld sources", arguments: snapshots.count)
		UndoableRemoval.announce(UndoableRemoval(
			title: title,
			restore: {
				for snapshot in snapshots { _restore(snapshot) }
				return true
			},
			discard: {}
		))
	}

	private static func _restore(_ snapshot: Snapshot) {
		// The user's own previously saved configuration: the transport policy was applied
		// when it was first added, as with a backup restore.
		Storage.shared.addSource(
			snapshot.url,
			name: snapshot.name,
			identifier: snapshot.identifier,
			iconURL: snapshot.iconURL,
			enforceTransportPolicy: false
		) { error in
			if let error { Toast.error(error.localizedDescription) }
		}
		// Keep the row where it was in date-ordered lists.
		if let date = snapshot.date,
		   let restored = Storage.shared.getSources().first(where: { $0.identifier == snapshot.identifier }) {
			restored.date = date
			Storage.shared.saveContext()
		}
	}
}
