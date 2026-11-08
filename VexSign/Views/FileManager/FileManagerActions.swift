//
//  FileManagerActions.swift
//  VexSign
//
//  Every write the File Manager can make inside Documents — create, import, rename, duplicate,
//  move, delete, share. They live in one place because two things have to stay in step: the
//  files on disk, and the Library / Certificates rows in Core Data that point at them.
//
//  Deleting `Signed/<uuid>` here deletes the Library entry too; deleting something *inside* it
//  warns first, because the app in the Library then points at a bundle that no longer works.
//

import Foundation
import UIKit
import NimbleExtensions

@MainActor
enum FileManagerActions {
	private static var _fileManager: FileManager { FileManager.default }

	// MARK: - Ownership

	/// A Documents folder the app itself also tracks in the database.
	enum LibraryOwner {
		case app(AppInfoPresentable)
		case certificate(CertificatePair)

		var title: String {
			switch self {
			case .app(let app): app.name ?? .localized("Unknown")
			case .certificate(let cert): cert.nickname ?? .localized("Certificate")
			}
		}
	}

	/// The app or certificate a `<root>/<uuid>` folder belongs to. Only matches the folder
	/// itself — anything deeper is "inside" it (see `isInsideLibraryFolder`).
	static func owner(of url: URL) -> LibraryOwner? {
		guard let match = _libraryMatch(of: url), match.isFolder else { return nil }
		return _owner(for: match)
	}

	/// True for anything at or below one of the app's own `Signed/<uuid>` / `Unsigned/<uuid>` /
	/// `Certificates/<uuid>` folders — the paths where a stray delete breaks a Library row.
	static func isInsideLibraryFolder(_ url: URL) -> Bool {
		_libraryMatch(of: url) != nil
	}

	/// Extra line for a delete confirmation, or `nil` when nothing here is tracked.
	static func deletionWarning(for urls: [URL]) -> String? {
		var entries: [String] = []
		var broken: [String] = []

		for url in urls {
			guard let match = _libraryMatch(of: url), let owner = _owner(for: match) else { continue }
			let name = owner.title
			if match.isFolder { entries.append(name) } else { broken.append(name) }
		}

		var lines: [String] = []
		if !entries.isEmpty {
			lines.append(.localized("%@ is managed by VexSign — its Library entry is removed as well.", arguments: Array(Set(entries)).sorted().joined(separator: ", ")))
		}
		if !broken.isEmpty {
			lines.append(.localized("This is inside %@, which is still in the Library. What is left of it may no longer open.", arguments: Array(Set(broken)).sorted().joined(separator: ", ")))
		}
		return lines.isEmpty ? nil : lines.joined(separator: "\n")
	}

	// MARK: - Create

	static func sanitized(_ name: String) -> String {
		name
			.replacingOccurrences(of: "/", with: "-")
			.replacingOccurrences(of: ":", with: "-")
			.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	/// `name.txt` → `name 2.txt` when the first name is taken, so imports never clobber.
	static func uniqueURL(for name: String, in directory: URL) -> URL {
		let candidate = directory.appendingPathComponent(name)
		guard _fileManager.fileExists(atPath: candidate.path) else { return candidate }

		let base = (name as NSString).deletingPathExtension
		let ext = (name as NSString).pathExtension
		for index in 2...999 {
			let next = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
			let url = directory.appendingPathComponent(next)
			if !_fileManager.fileExists(atPath: url.path) { return url }
		}
		return directory.appendingPathComponent(UUID().uuidString + (ext.isEmpty ? "" : ".\(ext)"))
	}

	@discardableResult
	static func createFolder(named rawName: String, in directory: URL) -> URL? {
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
			Toast.success(.localized("Folder created"), systemImage: "folder.badge.plus")
			return target
		} catch {
			Toast.error(error.localizedDescription, duration: .long)
			return nil
		}
	}

	/// An empty file, so a config or a `.strings` file can be written from scratch.
	@discardableResult
	static func createTextFile(named rawName: String, in directory: URL) -> URL? {
		var name = sanitized(rawName)
		guard !name.isEmpty else {
			Toast.error(.localized("Enter a file name"))
			return nil
		}
		if (name as NSString).pathExtension.isEmpty { name += ".txt" }

		let target = directory.appendingPathComponent(name)
		guard !_fileManager.fileExists(atPath: target.path) else {
			Toast.error(.localized("Something with that name already exists here"))
			return nil
		}

		do {
			try Data().write(to: target, options: .atomic)
			Toast.success(.localized("File created"), systemImage: "doc.badge.plus")
			return target
		} catch {
			Toast.error(error.localizedDescription, duration: .long)
			return nil
		}
	}

	/// Copies picked files in. `overwrite` decides what happens to a name that already exists;
	/// otherwise the copy is renamed the same way Finder would.
	@discardableResult
	static func importFiles(_ urls: [URL], into directory: URL, overwrite: Bool = false) -> Int {
		var added = 0

		for url in urls {
			let scoped = url.startAccessingSecurityScopedResource()
			defer { if scoped { url.stopAccessingSecurityScopedResource() } }

			let existing = directory.appendingPathComponent(url.lastPathComponent)
			let target = _fileManager.fileExists(atPath: existing.path)
				? (overwrite ? existing : uniqueURL(for: url.lastPathComponent, in: directory))
				: existing

			do {
				if _fileManager.fileExists(atPath: target.path) {
					try _fileManager.removeItem(at: target)
				}
				try _fileManager.copyItem(at: url, to: target)
				added += 1
			} catch {
				Toast.error(error.localizedDescription, duration: .long)
			}
		}

		guard added > 0 else { return 0 }
		Toast.success(
			.localized("Imported %lld item(s)", arguments: added),
			systemImage: "square.and.arrow.down"
		)
		return added
	}

	// MARK: - Modify

	@discardableResult
	static func rename(_ url: URL, to rawName: String) -> URL? {
		let name = sanitized(rawName)
		guard !name.isEmpty, name != url.lastPathComponent else { return nil }

		let target = url.deletingLastPathComponent().appendingPathComponent(name)
		guard !_fileManager.fileExists(atPath: target.path) else {
			Toast.error(.localized("Something with that name already exists here"))
			return nil
		}

		do {
			try _fileManager.moveItem(at: url, to: target)
			Toast.success(.localized("Renamed"), systemImage: "pencil")
			return target
		} catch {
			Toast.error(error.localizedDescription, duration: .long)
			return nil
		}
	}

	@discardableResult
	static func duplicate(_ url: URL) -> URL? {
		let directory = url.deletingLastPathComponent()
		let name = url.lastPathComponent
		let base = (name as NSString).deletingPathExtension
		let ext = (name as NSString).pathExtension
		let copyName = ext.isEmpty ? "\(base) copy" : "\(base) copy.\(ext)"
		let target = uniqueURL(for: copyName, in: directory)

		do {
			try _fileManager.copyItem(at: url, to: target)
			Toast.success(.localized("Duplicated"), systemImage: "plus.square.on.square")
			return target
		} catch {
			Toast.error(error.localizedDescription, duration: .long)
			return nil
		}
	}

	@discardableResult
	static func move(_ url: URL, into directory: URL) -> URL? {
		let target = directory.appendingPathComponent(url.lastPathComponent)
		guard target.standardizedFileURL != url.standardizedFileURL else { return nil }

		guard !_fileManager.fileExists(atPath: target.path) else {
			Toast.error(.localized("Something with that name already exists here"))
			return nil
		}

		do {
			try _fileManager.moveItem(at: url, to: target)
			Toast.success(.localized("Moved"), systemImage: "arrow.right.doc.on.clipboard")
			return target
		} catch {
			Toast.error(error.localizedDescription, duration: .long)
			return nil
		}
	}

	// MARK: - Delete

	/// Removes the paths, keeping the Library and Certificates in sync. Returns how many were
	/// removed from disk (the managed ones count as one deletion each).
	@discardableResult
	static func delete(_ urls: [URL]) -> Int {
		var removed = 0
		var apps: [AppInfoPresentable] = []

		for url in urls {
			switch owner(of: url) {
			case .app(let app):
				// `deleteApps` removes the folder and the Core Data row together.
				apps.append(app)
				removed += 1
			case .certificate(let cert):
				Storage.shared.deleteCertificate(for: cert)
				removed += 1
			case .none:
				if (try? _fileManager.removeItem(at: url)) != nil { removed += 1 }
			}
		}

		Storage.shared.deleteApps(apps)

		if removed > 0 {
			// The Storage screen reads a cached scan; make it reflect this immediately.
			StorageManager.shared.refresh()
			Toast.success(
				removed == 1 ? .localized("Deleted") : .localized("Deleted %lld items", arguments: removed),
				systemImage: "trash"
			)
		}
		return removed
	}

	// MARK: - Share

	static func share(_ url: URL) {
		guard let shareable = FileExporter.shareableURL(for: url) else {
			Toast.error(.localized("Couldn't prepare that file for sharing"))
			return
		}
		UIActivityViewController.show(activityItems: [shareable])
	}

	static func export(_ urls: [URL]) {
		DocumentPicker.export(urls)
	}

	static func copyPath(_ url: URL) {
		UIPasteboard.general.string = url.path
		Toast.success(.localized("Path copied"), systemImage: "doc.on.doc")
	}

	/// Same shortcut the IPA Explorer offers: a `.dylib`/`.deb` found in Files can go straight
	/// into the Tweak Manager library.
	static func sendToTweakManager(_ url: URL) {
        Task { @MainActor in

            guard await TweakManager.shared.importTweak(name: url.lastPathComponent, fromFiles: [url]) != nil else {
                Toast.error(.localized("Couldn't import tweak"))
                return
            }
            Toast.success(.localized("Added to Tweak Manager"), systemImage: "wrench.and.screwdriver.fill")
        }
	}

	/// Whether the file is worth offering to the Tweak Manager.
	static func isTweakArchive(_ url: URL) -> Bool {
		["dylib", "deb", "framework", "bundle", "tipa"].contains(url.pathExtension.lowercased())
	}

	// MARK: - Internal

	/// The three Documents folders the app itself owns.
	private enum Root: CaseIterable {
		case signed
		case unsigned
		case certificates

		var url: URL {
			switch self {
			case .signed: FileManager.default.signed
			case .unsigned: FileManager.default.unsigned
			case .certificates: FileManager.default.certificates
			}
		}
	}

	private struct LibraryMatch {
		let uuid: String
		let root: Root
		/// The path *is* the `<uuid>` folder, not something inside it.
		let isFolder: Bool
	}

	private static func _libraryMatch(of url: URL) -> LibraryMatch? {
		let path = url.standardizedFileURL.path

		for root in Root.allCases {
			let prefix = root.url.standardizedFileURL.path + "/"
			guard path.hasPrefix(prefix) else { continue }

			let remainder = String(path.dropFirst(prefix.count))
			let uuid = String(remainder.prefix { $0 != "/" })
			guard !uuid.isEmpty else { return nil }

			return LibraryMatch(uuid: uuid, root: root, isFolder: remainder == uuid)
		}

		return nil
	}

	private static func _owner(for match: LibraryMatch) -> LibraryOwner? {
		switch match.root {
		case .signed, .unsigned:
			return Storage.shared.app(withUuid: match.uuid).map { .app($0) }
		case .certificates:
			return Storage.shared.getAllCertificates()
				.first { $0.uuid == match.uuid }
				.map { .certificate($0) }
		}
	}
}
