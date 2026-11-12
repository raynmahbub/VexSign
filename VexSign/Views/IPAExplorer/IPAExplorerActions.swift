//
//  IPAExplorerActions.swift
//  VexSign
//
//  The edits the explorer can make to an app bundle: new folders, imported files, rename,
//  replace and delete. All of them go through here so every path marks the workspace dirty and
//  reports the same way.
//

import Foundation
import UIKit
import NimbleExtensions

@MainActor
enum IPAExplorerActions {
	private static var _fileManager: FileManager { FileManager.default }

	/// Keeps a rename or a new folder inside its own directory.
	static func sanitized(_ name: String) -> String {
		name
			.replacingOccurrences(of: "/", with: "-")
			.replacingOccurrences(of: ":", with: "-")
			.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	// MARK: Create

	@discardableResult
	static func createFolder(named rawName: String, in directory: URL, workspace: IPAWorkspace) -> URL? {
		let name = sanitized(rawName)
		guard !name.isEmpty else {
			Toast.error(.localized("Enter a folder name"))
			return nil
		}

		let target = directory.appendingPathComponent(name, isDirectory: true)
		guard !_fileManager.fileExists(atPath: target.path) else {
			Toast.error(.localized("Something with that name already exists here"))
			return nil
		}

		do {
			let lease = try await workspace.acquireEditingLease()
			defer { withExtendedLifetime(lease) {} }
			try _fileManager.createDirectoryIfNeeded(at: target)
			workspace.journalChange(kind: .added, url: target, backupName: nil)
			workspace.markDirty()
			Toast.success(.localized("Folder created"), systemImage: "folder.badge.plus")
			return target
		} catch {
			Toast.error(error.localizedDescription, duration: .long)
			return nil
		}
	}

	/// Copies picked files (or folders) into `directory`, overwriting on request.
	@discardableResult
static func importFiles(_ urls: [URL], into directory: URL, workspace: IPAWorkspace, overwrite: Bool = false) async -> Int {
		let lease: AppOperationRegistry.Lease
		do {
			lease = try await workspace.acquireEditingLease()
		} error {
			Toast.error(error.localizedDescription, duration: .long)
			return 0
		}
		defer { withExtendedLifetime(lease) {} }
		var added = 0

		for url in urls {
			let scoped = url.startAccessingSecurityScopedResource()
			defer { if scoped { url.stopAccessingSecurityScopedResource() } }

			let target = directory.appendingPathComponent(url.lastPathComponent)

			// Capture the original before any remove so an overwrite can be undone.
			let existedBefore = _fileManager.fileExists(atPath: target.path)

			if existedBefore {
				guard overwrite else { continue }
			}

			var backupName: String?
			do {
				// First copy for an existing path is "modified" (original bytes matter); a new
				// path is "added" (undo = remove).
				if existedBefore {
					backupName = try workspace.backupForUndo(target)
				} else {
					backupName = nil
				}

				if existedBefore {
					try _replaceItem(at: target, with: url)
				} else {
					try _fileManager.copyItem(at: url, to: target)
				}
				// A replaced executable has to stay runnable.
				_applyExecutablePermissionsIfNeeded(target)
				workspace.journalChange(kind: existedBefore ? .modified : .added, url: target, backupName: backupName)
				added += 1
			} catch {
				if existedBefore {
					workspace.discardUndoBackup(backupName)
				}
				Toast.error(error.localizedDescription, duration: .long)
			}
		}

		guard added > 0 else { return 0 }
		workspace.markDirty()
		Toast.success(
			String.localized("Added %lld items", arguments: added),
			systemImage: "doc.badge.plus"
		)
		return added
	}

	/// Atomically saves editor content after a durable archive-workspace undo copy is ready.
	static func save(data: Data, to url: URL, workspace: IPAWorkspace) async throws {
		let lease = try await workspace.acquireEditingLease()
		defer { withExtendedLifetime(lease) {} }
		let backupName = try workspace.backupForUndo(url)
		do {
			try data.write(to: url, options: .atomic)
		} catch {
			workspace.discardUndoBackup(backupName)
			throw error
		}
		workspace.journalChange(kind: .modified, url: url, backupName: backupName)
		workspace.markDirty()
	}

	// MARK: Modify

	/// Renames in place and returns the new URL.
	@discardableResult
	static func rename(_ entry: IPAFileEntry, to rawName: String, workspace: IPAWorkspace) async -> URL? {
		let name = sanitized(rawName)
		guard !name.isEmpty, name != entry.name else { return nil }

		let target = entry.url.deletingLastPathComponent().appendingPathComponent(name)
		guard !_fileManager.fileExists(atPath: target.path) else {
			Toast.error(.localized("Something with that name already exists here"))
			return nil
		}

		do {
			let lease = try await workspace.acquireEditingLease()
			defer { withExtendedLifetime(lease) {} }
			// A rename is recorded as two journal entries so undo is exact: "removed" restores
			// the original name+bytes, "added" drops the moved-away file.
			let backupName = try workspace.backupForUndo(entry.url)
			try _fileManager.moveItem(at: entry.url, to: target)
			workspace.journalChange(kind: .removed, url: entry.url, backupName: backupName)
			workspace.journalChange(kind: .added, url: target, backupName: nil)
			workspace.markDirty()
			Toast.success(.localized("Renamed"), systemImage: "pencil")
			return target
		} catch {
			Toast.error(error.localizedDescription, duration: .long)
			return nil
		}
	}

	/// Swaps a file's contents for the picked one, keeping the name.
	@discardableResult
	static func replace(_ entry: IPAFileEntry, with url: URL, workspace: IPAWorkspace) async -> Bool {
		let scoped = url.startAccessingSecurityScopedResource()
		defer { if scoped { url.stopAccessingSecurityScopedResource() } }

		do {
			let lease = try await workspace.acquireEditingLease()
			defer { withExtendedLifetime(lease) {} }
			let backupName = try workspace.backupForUndo(entry.url)
			do {
				try _replaceItem(at: entry.url, with: url)
			} catch {
				workspace.discardUndoBackup(backupName)
				throw error
			}
			_applyExecutablePermissionsIfNeeded(entry.url)
			workspace.journalChange(kind: .modified, url: entry.url, backupName: backupName)
			workspace.markDirty()
			Toast.success(.localized("File replaced"), systemImage: "arrow.triangle.2.circlepath")
			return true
		} catch {
			Toast.error(error.localizedDescription, duration: .long)
			return false
		}
	}

	static func delete(_ entry: IPAFileEntry, workspace: IPAWorkspace) async {
		do {
			let lease = try await workspace.acquireEditingLease()
			defer { withExtendedLifetime(lease) {} }
			let backupName = try workspace.backupForUndo(entry.url)
			try _fileManager.removeItem(at: entry.url)
			workspace.journalChange(kind: .removed, url: entry.url, backupName: backupName)
			workspace.markDirty()
			Toast.success(.localized("Deleted"), systemImage: "trash")
		} catch {
			Toast.error(error.localizedDescription, duration: .long)
		}
	}

	// MARK: Share

	static func share(_ entry: IPAFileEntry) {
		guard let url = FileExporter.shareableURL(for: entry.url) else {
			Toast.error(.localized("Couldn't prepare that file for sharing"))
			return
		}
		UIActivityViewController.show(activityItems: [url])
	}

	static func copyPath(_ entry: IPAFileEntry) {
		UIPasteboard.general.string = entry.url.path
		Toast.success(.localized("Path copied"), systemImage: "doc.on.doc")
	}

	/// "Send to Tweak Manager" so a dylib inside the app can be reused elsewhere.
	static func sendToTweakManager(_ entry: IPAFileEntry) {
        Task { @MainActor in

            guard await TweakManager.shared.importTweak(name: entry.name, fromFiles: [entry.url]) != nil else {
                Toast.error(.localized("Couldn't import tweak"))
                return
            }
            Toast.success(.localized("Added to Tweak Manager"), systemImage: "wrench.and.screwdriver.fill")
        }
	}

	// MARK: Helpers

	/// Copy first, then ask FileManager to replace the destination as one
	/// filesystem operation. The staged source is a sibling, keeping it on the
	/// same volume and leaving the original untouched if staging fails.
	private static func _replaceItem(at target: URL, with source: URL) throws {
		let parent = target.deletingLastPathComponent()
		let replacement = parent.appendingPathComponent(".vexsign-replacement-\(UUID().uuidString)")
		defer { _removeStagingItem(replacement) }

		try _fileManager.copyItem(at: source, to: replacement)
		_ = try _fileManager.replaceItemAt(
			target,
			withItemAt: replacement,
			backupItemName: nil,
			options: []
		)
	}

	private static func _removeStagingItem(_ url: URL) {
		guard _fileManager.fileExists(atPath: url.path) else { return }
		do {
			try _fileManager.removeItem(at: url)
		} catch {
			FileLogger.error("IPA Explorer staging cleanup failed at \(url.lastPathComponent): \(error.localizedDescription)", category: "ipa")
		}
	}

	/// Mach-O files have to stay executable or iOS refuses to launch/load them.
	private static func _applyExecutablePermissionsIfNeeded(_ url: URL) {
		guard let head = IPAFileLoader.head(of: url, count: 8), head.count >= 4 else { return }
		let bytes = [UInt8](head.prefix(4))
		let magic = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
		let machOMagics: [UInt32] = [0xfeedface, 0xfeedfacf, 0xcefaedfe, 0xcffaedfe, 0xcafebabe, 0xbebafeca, 0xcafebabf]
		guard machOMagics.contains(magic) else { return }
		try? _fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
	}
}
