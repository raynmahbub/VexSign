//
//  CoreDataStoreRecovery.swift
//  VexSign
//
//  Non-destructive quarantine recovery for unreadable SQLite Core Data stores.
//

import Foundation
import OSLog

/// Moves unreadable Core Data SQLite files out of the way into `QuarantinedStores/`
/// so a fresh store can open without deleting signed/unsigned app bundles or certificates.
enum CoreDataStoreRecovery {
	struct Notice: Equatable, Sendable {
		let quarantineFolderName: String
		let recoveredAt: Date
		let summary: String
	}

	struct Outcome: Equatable, Sendable {
		let movedFiles: [URL]
		let quarantineDirectory: URL
		let notice: Notice
	}

	static func quarantineStore(
		at storeURL: URL?,
		quarantineRoot: URL? = nil,
		reason: String,
		fileManager: FileManager = .default,
		now: Date = Date()
	) throws -> Outcome? {
		guard let storeURL else { return nil }

		let base = storeURL.deletingPathExtension()
		let sidecars = [
			base.appendingPathExtension("sqlite"),
			base.appendingPathExtension("sqlite-wal"),
			base.appendingPathExtension("sqlite-shm")
		]
		let existing = sidecars.filter { fileManager.fileExists(atPath: $0.path) }

		let root = quarantineRoot
			?? storeURL.deletingLastPathComponent().appendingPathComponent("QuarantinedStores", isDirectory: true)
		let stamp = _timestamp(from: now)
		let folderName = "VexSign-\(stamp)-\(UUID().uuidString.prefix(8))"
		let destinationDir = root.appendingPathComponent(folderName, isDirectory: true)

		var moved: [URL] = []
		if !existing.isEmpty {
			try fileManager.createDirectory(at: destinationDir, withIntermediateDirectories: true)
			for source in existing {
				let dest = destinationDir.appendingPathComponent(source.lastPathComponent)
				try fileManager.moveItem(at: source, to: dest)
				moved.append(dest)
			}
		}

		let notice = Notice(
			quarantineFolderName: folderName,
			recoveredAt: now,
			summary: LogRedaction.redact(reason)
		)
		return Outcome(movedFiles: moved, quarantineDirectory: destinationDir, notice: notice)
	}

	private static func _timestamp(from date: Date) -> String {
		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.timeZone = TimeZone(secondsFromGMT: 0)
		formatter.dateFormat = "yyyyMMdd-HHmmss"
		return formatter.string(from: date)
	}
}
