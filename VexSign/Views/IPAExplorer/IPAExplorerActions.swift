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
	static func importFiles(_ urls: [URL], into directory: URL, workspace: IPAWorkspace, overwrite: Bool = false) -> Int {
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

			do {
				// First copy for an existing path is "modified" (original bytes matter); a new
				// path is "added" (undo = remove).
				let backupName = existedBefore ? workspace.backupForUndo(target) : nil

				if existedBefore {
					try _fileManager.removeItem(at: target)
				}
				try _fileManager.copyItem(at: url, to: target)
				// A replaced executable has to stay runnable.
				_applyExecutablePermissionsIfNeeded(target)
				workspace.journalChange(kind: existedBefore ? .modified : .added, url: target, backupName: backupName)
				added += 1
			} catch {
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

	// MARK: Modify

	/// Renames in place and returns the new URL.
	@discardableResult
	static func rename(_ entry: IPAFileEntry, to rawName: String, workspace: IPAWorkspace) -> URL? {
		let name = sanitized(rawName)
		guard !name.isEmpty, name != entry.name else { return nil }

		let target = entry.url.deletingLastPathComponent().appendingPathComponent(name)
		guard !_fileManager.fileExists(atPath: target.path) else {
			Toast.error(.localized("Something with that name already exists here"))
			return nil
		}

		do {
			// A rename is recorded as two journal entries so undo is exact: "removed" restores
			// the original name+bytes, "added" drops the moved-away file.
			let backupName = workspace.backupForUndo(entry.url)
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
	static func replace(_ entry: IPAFileEntry, with url: URL, workspace: IPAWorkspace) -> Bool {
		let scoped = url.startAccessingSecurityScopedResource()
		defer { if scoped { url.stopAccessingSecurityScopedResource() } }

		do {
			let backupName = workspace.backupForUndo(entry.url)
			try _fileManager.removeItem(at: entry.url)
			try _fileManager.copyItem(at: url, to: entry.url)
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

	static func delete(_ entry: IPAFileEntry, workspace: IPAWorkspace) {
		do {
			let backupName = workspace.backupForUndo(entry.url)
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
