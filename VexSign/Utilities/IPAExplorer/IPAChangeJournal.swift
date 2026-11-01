//
//  IPAChangeJournal.swift
//  VexSign
//
//  Undo and history for the IPA Explorer. Every mutation (add / edit / rename-replace / delete)
//  is recorded in a small manifest with a backup of the original bytes, so one bad edit can be
//  reverted per file — or the whole session discarded — instead of rebuilding a broken IPA.
//

import Foundation
import NimbleExtensions

// MARK: - Change
struct IPAChange: Identifiable, Equatable {
	enum Kind: String, Codable {
		case added
		case modified
		case removed
	}

	let id: String
	let relativePath: String
	let kind: Kind
	/// Filename inside the journal's `Backups/` folder holding the original bytes (nil for added).
	let backupName: String?
	let date: Date

	var title: String {
		switch kind {
		case .added: .localized("Added")
		case .modified: .localized("Edited")
		case .removed: .localized("Removed")
		}
	}

	/// Symbol shown next to the change in the "what changed" list.
	var symbol: String {
		switch kind {
		case .added: "plus.circle.fill"
		case .modified: "pencil.circle.fill"
		case .removed: "minus.circle.fill"
		}
	}
}

// MARK: - Journal
@MainActor
final class IPAChangeJournal {
	let root: URL
	let backupsDirectory: URL
	let manifestURL: URL

	private(set) var changes: [IPAChange] = []

	init(directory: URL) {
		self.root = directory
		self.backupsDirectory = directory.appendingPathComponent("Backups", isDirectory: true)
		self.manifestURL = directory.appendingPathComponent("changes.json")

		try? FileManager.default.createDirectoryIfNeeded(at: backupsDirectory)
		_load()
	}

	var isEmpty: Bool { changes.isEmpty }

	/// File's path relative to the workspace's container, so paths stay stable across devices.
	static func relativePath(_ url: URL, container: URL) -> String {
		let file = url.standardizedFileURL.path
		let base = container.standardizedFileURL.path
		guard file.hasPrefix(base) else { return url.lastPathComponent }
		return String(file.dropFirst(base.count).drop { $0 == "/" })
	}

	// MARK: Recording

	/// Replaces an existing entry/change for the same path: capturing again after a change
	/// keeps the *original* bytes (only the first capture persists).
	func record(change: IPAChange) {
		let path = change.relativePath

		if
			let existingIndex = changes.firstIndex(where: { $0.relativePath == path }),
			case .added = changes[existingIndex].kind,
			change.kind != .added {
			// An "added" file that is now edited/replaced: keep the added entry (undo = remove).
			// The bytes are user-provided, so there is no original to restore.
			return
		}

		if let existingIndex = changes.firstIndex(where: { $0.relativePath == path }) {
			// A second edit to the same file: keep only the first (original) backup.
			if changes[existingIndex].backupName != nil, change.backupName != nil {
				removeBackup(change.backupName)
			}
			return
		}

		changes.append(change)
		persist()
	}

	func isRecorded(_ path: String) -> Bool {
		changes.contains { $0.relativePath == path }
	}

	// MARK: Backups

	func backup(at url: URL, container: URL) -> String? {
		let fileManager = FileManager.default
		guard fileManager.fileExists(atPath: url.path) else { return nil }

		try? fileManager.createDirectoryIfNeeded(at: backupsDirectory)

		let name = UUID().uuidString
		let backupURL = backupsDirectory.appendingPathComponent(name)
		do {
			try fileManager.copyItem(at: url, to: backupURL)
			return name
		} catch {
			// Try byte-level copy when the file provider refuses a direct copy.
			if let data = try? Data(contentsOf: url) {
				do {
					try data.write(to: backupURL)
				} catch {
					// Undo depends on this copy. A name for a backup that is not there would make
					// the journal promise a rollback it cannot deliver.
					FileLogger.error(
						"IPA change journal backup failed: \(error.localizedDescription)",
						category: "ipa"
					)
					return nil
				}
				return name
			}
			return nil
		}
	}

	private func removeBackup(_ name: String?) {
		guard let name else { return }
		try? FileManager.default.removeItem(at: backupsDirectory.appendingPathComponent(name))
	}

	// MARK: Undo

	/// Reverts the newest change touching `path`, then drops it from the manifest.
	@discardableResult
	func undo(path: String, restoringTo container: URL) -> Bool {
		guard let index = changes.lastIndex(where: { $0.relativePath == path }) else { return false }
		let change = changes[index]

		let target = container.appendingPathComponent(change.relativePath)
		let fileManager = FileManager.default

		do {
			switch change.kind {
			case .added:
				// Remove the added file/folder; leave a non-empty folder alone.
				var isDirectory: ObjCBool = false
				if fileManager.fileExists(atPath: target.path, isDirectory: &isDirectory), isDirectory.boolValue {
					let contents = (try? fileManager.contentsOfDirectory(atPath: target.path)) ?? []
					guard contents.isEmpty else { return false }
				}
				try fileManager.removeItem(at: target)
			case .modified, .removed:
				guard let backupName = change.backupName else { return false }
				let backup = backupsDirectory.appendingPathComponent(backupName)
				guard fileManager.fileExists(atPath: backup.path) else { return false }
				if fileManager.fileExists(atPath: target.path) {
					try fileManager.removeItem(at: target)
				}
				try fileManager.copyItem(at: backup, to: target)
			}
		} catch {
			return false
		}

		removeBackup(change.backupName)
		changes.remove(at: index)
		persist()
		return true
	}

	/// Drops the whole journal (after a successful rebuild) without touching the files.
	func clearAll() {
		changes.removeAll()
		try? FileManager.default.removeItem(at: backupsDirectory)
		try? FileManager.default.removeItem(at: manifestURL)
	}

	/// Reverts every change, newest first, restoring the app bundle to its pre-session state.
	@discardableResult
	func discardAll(restoringTo container: URL) -> Int {
		var reverted = 0
		while let change = changes.last {
			let path = change.relativePath
			if undo(path: path, restoringTo: container) {
				reverted += 1
			} else {
				break
			}
		}
		return reverted
	}

	// MARK: Persistence

	private func persist() {
		let fileManager = FileManager.default
		try? fileManager.createDirectoryIfNeeded(at: root)

		let payload = changes.map { change -> [String: Any] in
			[
				"id": change.id,
				"relativePath": change.relativePath,
				"kind": change.kind.rawValue,
				"backupName": change.backupName as Any,
				"date": change.date.timeIntervalSince1970
			]
		}

		if let data = try? JSONSerialization.data(withJSONObject: payload,
			options: [.prettyPrinted]) {
			try? data.write(to: manifestURL, options: .atomic)
		}
	}

	private func _load() {
		guard
			let data = try? Data(contentsOf: manifestURL),
			let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
		else {
			return
		}

		changes = raw.compactMap { dict -> IPAChange? in
			guard
				let id = dict["id"] as? String,
				let path = dict["relativePath"] as? String,
				let kindRaw = dict["kind"] as? String,
				let kind = IPAChange.Kind(rawValue: kindRaw)
			else {
				return nil
			}

			return IPAChange(
				id: id,
				relativePath: path,
				kind: kind,
				backupName: dict["backupName"] as? String,
				date: Date(timeIntervalSince1970: (dict["date"] as? TimeInterval) ?? Date().timeIntervalSince1970)
			)
		}
	}
}
