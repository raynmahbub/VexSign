//
//  IPAWorkspace.swift
//  VexSign
//
//  Opens an IPA (or a library app) as a browsable, editable working copy and puts it back
//  together again. This is the engine behind the IPA Explorer.
//

import Foundation
import SwiftUI
import Zip
import NimbleExtensions

// MARK: - Errors
enum IPAWorkspaceError: LocalizedError {
	case payloadNotFound
	case appNotFound
	case extractionFailed(String)
	case rebuildFailed(String)
	case empty
	case noCertificate

	var errorDescription: String? {
		switch self {
		case .payloadNotFound:	.localized("No Payload folder was found inside this IPA. It may not be an app archive.")
		case .appNotFound:		.localized("No .app bundle was found inside the Payload folder.")
		case .extractionFailed(let reason):	.localized("The IPA could not be opened: %@", arguments: reason)
		case .rebuildFailed(let reason):	.localized("The IPA could not be rebuilt: %@", arguments: reason)
		case .empty:			.localized("Nothing to save yet.")
		case .noCertificate:	.localized("Signing needs a certificate. Import one in Settings → Certificates, or sign with the default signing option.")
		}
	}
}

// MARK: - Record
/// One workspace on disk, used for the "Recent" list on the explorer's home screen.
struct IPAWorkspaceRecord: Identifiable, Hashable {
	let id: String
	let name: String
	let date: Date
	let isLibraryApp: Bool

	var url: URL { IPAWorkspace.root.appendingPathComponent(id, isDirectory: true) }
}

// MARK: - Workspace
@MainActor
final class IPAWorkspace: ObservableObject, Identifiable {
	enum Source: Equatable {
		/// An IPA copied into the workspace and extracted.
		case archive(fileName: String)
		/// A live app bundle in the library (`Documents/Signed|Unsigned/<uuid>`).
		case libraryApp(uuid: String, isSigned: Bool)
	}

	let id: String
	/// `.app` bundle — where browsing starts for both kinds.
	let appURL: URL
	/// Workspace root (archive) or the app's uuid folder (library), i.e. what contains `appURL`.
	let containerURL: URL
	let source: Source
	/// Display name — the app's name, falling back to the bundle name.
	private(set) var name: String

	/// Edits made since the last save/export. Library apps write straight through, so this only
	/// drives the "unsaved changes" warning for archive workspaces.
	@Published private(set) var changeCount = 0
	@Published private(set) var isBusy = false
	@Published private(set) var progress: Double = 0
	@Published private(set) var lastError: String?
	/// Last IPA produced by `rebuild()`.
	@Published private(set) var builtArchive: URL?

	/// Undo / history journal for this workspace (archive workspaces only; library apps are
	/// edited in place, so their history is the Files app's own).
	let journal: IPAChangeJournal?

	private let _fileManager = FileManager.default

	private init(id: String, appURL: URL, containerURL: URL, source: Source, name: String) {
		self.id = id
		self.appURL = appURL
		self.containerURL = containerURL
		self.source = source
		self.name = name

		// The journal lives next to the workspace root for archive workspaces; library apps are
		// edited in place with no separate copy to snapshot, so they get no journal.
		if case .archive = source {
			let journalDirectory = Self.root.appendingPathComponent(id, isDirectory: true)
			journal = IPAChangeJournal(directory: journalDirectory)
		} else {
			journal = nil
		}
	}

	// MARK: Computed

	var isLibraryApp: Bool {
		if case .libraryApp = source { return true }
		return false
	}

	var isDirty: Bool { changeCount > 0 }

	var sourceDescription: String {
		switch source {
		case .archive(let fileName): 	fileName
		case .libraryApp(_, let isSigned): isSigned ? .localized("Signed App") : .localized("Imported App")
		}
	}

	/// `Payload/…app`-style path shown under the title.
	var displayPath: String {
		let container = containerURL.standardizedFileURL.path
		let app = appURL.standardizedFileURL.path
		guard app.hasPrefix(container) else { return appURL.lastPathComponent }
		return String(app.dropFirst(container.count).drop { $0 == "/" })
	}

	/// Everything inside the workspace, for the header total.
	var totalSize: Int64 { _fileManager.allocatedSize(at: containerURL) }

	// MARK: Opening

	/// Extracts an IPA into a fresh workspace. The original file is only read.
	static func open(ipa url: URL) async throws -> IPAWorkspace {
		let fileManager = FileManager.default
		let id = UUID().uuidString
		let workspaceRoot = Self.root.appendingPathComponent(id, isDirectory: true)
		let contents = workspaceRoot.appendingPathComponent("Contents", isDirectory: true)

		let scoped = url.startAccessingSecurityScopedResource()
		defer { if scoped { url.stopAccessingSecurityScopedResource() } }

		do {
			try fileManager.createDirectoryIfNeeded(at: contents)

			// Copy first so a file provider can't yank the source mid-extraction. A large IPA
			// takes a moment, so it happens off the main actor while the overlay is up.
			let localCopy = contents.appendingPathComponent(url.lastPathComponent)
			try? fileManager.removeItem(at: localCopy)
			try await Task.detached(priority: .userInitiated) {
				try FileManager.default.copyItem(at: url, to: localCopy)
			}.value

			let ext = url.pathExtension.lowercased()
			if ext == "ipa" { Zip.addCustomFileExtension("ipa") }
			if ext == "tipa" { Zip.addCustomFileExtension("tipa") }

			let destination = workspaceRoot.appendingPathComponent("Extracted", isDirectory: true)
			try fileManager.createDirectoryIfNeeded(at: destination)

			try await unzip(localCopy, to: destination)
			try? fileManager.removeItem(at: localCopy)

			guard let appURL = findApp(in: destination) else {
				try? fileManager.removeItem(at: workspaceRoot)
				throw IPAWorkspaceError.appNotFound
			}

			let workspace = IPAWorkspace(
				id: id,
				appURL: appURL,
				containerURL: destination,
				source: .archive(fileName: url.lastPathComponent),
				name: Bundle(url: appURL)?.name ?? appURL.deletingPathExtension().lastPathComponent
			)

			workspace._writeMetadata()
			return workspace
		} catch let error as IPAWorkspaceError {
			try? fileManager.removeItem(at: workspaceRoot)
			throw error
		} catch {
			try? fileManager.removeItem(at: workspaceRoot)
			throw IPAWorkspaceError.extractionFailed(error.localizedDescription)
		}
	}

	/// Opens a workspace that is already on disk (a recent one).
	static func open(recent record: IPAWorkspaceRecord) throws -> IPAWorkspace {
		let container = record.url.appendingPathComponent("Extracted", isDirectory: true)
		guard let appURL = findApp(in: container), let metadata = metadata(at: record.url) else {
			throw IPAWorkspaceError.appNotFound
		}

		return IPAWorkspace(
			id: record.id,
			appURL: appURL,
			containerURL: container,
			source: .archive(fileName: metadata.fileName),
			name: Bundle(url: appURL)?.name ?? appURL.deletingPathExtension().lastPathComponent
		)
	}

	/// Opens a library app in place — every edit lands directly in the app bundle.
	static func open(app: AppInfoPresentable) throws -> IPAWorkspace {
		guard
			let container = Storage.shared.getUuidDirectory(for: app),
			let appURL = Storage.shared.getAppDirectory(for: app)
		else {
			throw IPAWorkspaceError.appNotFound
		}

		return IPAWorkspace(
			id: app.uuid ?? UUID().uuidString,
			appURL: appURL,
			containerURL: container,
			source: .libraryApp(uuid: app.uuid ?? "", isSigned: app.isSigned),
			name: app.name ?? Bundle(url: appURL)?.name ?? appURL.lastPathComponent
		)
	}

	// MARK: Editing

	/// Records an edit so the explorer can warn before dropping unsaved archive changes.
	func markDirty() {
		changeCount += 1
		lastError = nil
		objectWillChange.send()
	}

	func clearDirty() {
		changeCount = 0
	}

	// MARK: Undo journal

	/// Backs up `url` for undo (only for archive workspaces) and returns the backup id.
	func backupForUndo(_ url: URL) -> String? {
		journal?.backup(at: url, container: containerURL)
	}

	/// Records a change so the "what changed" list and per-file undo know about it.
	/// `backupName == nil` is fine for newly-added files (undo = remove).
	func journalChange(kind: IPAChange.Kind, url: URL, backupName: String?) {
		guard let journal else { return }
		let change = IPAChange(
			id: UUID().uuidString,
			relativePath: IPAChangeJournal.relativePath(url, container: containerURL),
			kind: kind,
			backupName: backupName,
			date: Date()
		)
		journal.record(change: change)
	}

	/// Undoes the newest change on `url`. Returns whether anything was reverted.
	@discardableResult
	func undoChange(at url: URL) -> Bool {
		guard let journal else { return false }
		let path = IPAChangeJournal.relativePath(url, container: containerURL)
		let reverted = journal.undo(path: path, restoringTo: containerURL)
		if reverted { markDirty() }
		return reverted
	}

	/// Reverts the whole session. Returns how many files were restored.
	@discardableResult
	func discardChanges() -> Int {
		guard let journal else { return 0 }
		let reverted = journal.discardAll(restoringTo: containerURL)
		if reverted > 0 { markDirty() }
		return reverted
	}


	// MARK: Saving

	/// Rebuilds the IPA from the edited bundle and returns the file.
	///
	/// - Parameter to: where to write it. Defaults to a fresh file in `Documents/Archives`.
	@discardableResult
	func rebuild(to destination: URL? = nil) async throws -> URL {
		// An extracted IPA already has its Payload folder; a library app has to be wrapped in a
		// throwaway one so the archive comes out with the same layout.
		let payload = containerURL.appendingPathComponent("Payload", isDirectory: true)
		let hasPayload = _fileManager.fileExists(atPath: payload.path)
		let packaged = hasPayload ? payload : try _wrapInPayload()

		let target = destination ?? defaultArchiveURL()

		isBusy = true
		progress = 0
		defer {
			isBusy = false
			progress = 0
		}

		let compression = ZipCompression.allCases[safe: ArchiveHandler.getCompressionLevel()] ?? .DefaultCompression

		do {
			try await Task.detached(priority: .userInitiated) {
				try AppArchiver.zip(payload: packaged, to: target, compression: compression) { value in
					Task { @MainActor in self.progress = value }
				}
			}.value

			if !hasPayload { try? _fileManager.removeItem(at: packaged) }

			builtArchive = target
			changeCount = 0

			// A rebuilt IPA is a new clean baseline: nothing to undo from here.
			journal?.clearAll()

			return target
		} catch {
			if !hasPayload { try? _fileManager.removeItem(at: packaged) }
			throw IPAWorkspaceError.rebuildFailed(error.localizedDescription)
		}
	}

	/// Where "Save IPA" lands: `Documents/Archives/<name>_<timestamp>.ipa`.
	func defaultArchiveURL() -> URL {
		let stamp = Int(Date().timeIntervalSince1970)
		let safeName = name.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: "_")
		let base = safeName.isEmpty ? "App" : safeName
		return _fileManager.archives.appendingPathComponent("\(base)_edited_\(stamp).ipa")
	}

	/// Imports the rebuilt IPA back into the library through the normal import pipeline.
	func importIntoLibrary() async throws -> AppInfoPresentable {
		let ipa = try await rebuild()

		return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AppInfoPresentable, Error>) in
			FR.handlePackageFile(ipa) { result in
				continuation.resume(with: result)
			}
		}
	}

	/// The library app this workspace edits, when it is one.
	var libraryApp: AppInfoPresentable? {
		guard case .libraryApp(let uuid, _) = source else { return nil }
		return Storage.shared.app(withUuid: uuid)
	}

	/// Finishes the job: rebuilds (archive) or reuses the app in the library, signs it with the
	/// selected certificate and hands it straight to the installer.
	///
	/// This is the App-Store-shaped flow — edit, sign, install — with Auto Cleanup taking the
	/// leftovers away afterwards.
	@discardableResult
	func signAndInstall() async throws -> Signed {
		let target: AppInfoPresentable
		var temporary = false

		if let app = libraryApp {
			target = app
		} else {
			target = try await importIntoLibrary()
			temporary = true
		}

		let certificate = Storage.shared.getCertificate(for: UserDefaults.standard.integer(forKey: "vexsign.selectedCert"))
		let options = OptionsManager.shared.options.resolved(for: target)

		guard options.signingOption != .default || certificate != nil else {
			if temporary { Storage.shared.deleteApp(for: target) }
			throw IPAWorkspaceError.noCertificate
		}

		let signed: Signed
		do {
			signed = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Signed, Error>) in
				FR.signPackageFile(target, using: options, icon: nil, certificate: certificate) { result in
					continuation.resume(with: result)
				}
			}
		} catch {
			if temporary { Storage.shared.deleteApp(for: target) }
			throw error
		}

		// The copy that was signed is done either way: a re-sign replaces the old entry, an
		// import only existed to be signed.
		Storage.shared.deleteApp(for: target)

		InstallQueue.shared.enqueue(signed)
		return signed
	}

	/// Deletes the workspace's temporary files. Library apps are never touched.
	func discard() {
		guard !isLibraryApp else { return }
		try? _fileManager.removeItem(at: Self.root.appendingPathComponent(id, isDirectory: true))
	}

	// MARK: Filesystem

	private func _wrapInPayload() throws -> URL {
		let work = _fileManager.uniqueTemporaryDirectory("IPAWorkspacePayload")
		let payload = work.appendingPathComponent("Payload", isDirectory: true)
		try _fileManager.createDirectoryIfNeeded(at: payload)
		try _fileManager.copyItem(at: appURL, to: payload.appendingPathComponent(appURL.lastPathComponent))
		return payload
	}

	private func _writeMetadata() {
		let metadata: [String: Any] = [
			"fileName": sourceDescription,
			"date": Date().timeIntervalSince1970,
			"name": name
		]
		let url = Self.root.appendingPathComponent(id, isDirectory: true).appendingPathComponent(".workspace.json")
		try? JSONSerialization.data(withJSONObject: metadata, options: .prettyPrinted).write(to: url)
	}

	// MARK: Static helpers

	/// `Documents/IPAWorkspaces`
	// `nonisolated` so nonisolated contexts (e.g. `IPAWorkspaceRecord.url`) can use it;
	// it only does pure Foundation path math, so it is safe off the main actor.
	nonisolated static var root: URL {
		URL.documentsDirectory.appendingPathComponent("IPAWorkspaces", isDirectory: true)
	}

	static func metadata(at directory: URL) -> (fileName: String, date: Date)? {
		guard
			let data = try? Data(contentsOf: directory.appendingPathComponent(".workspace.json")),
			let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			let fileName = object["fileName"] as? String
		else {
			return nil
		}
		let date = (object["date"] as? TimeInterval).map { Date(timeIntervalSince1970: $0) } ?? Date()
		return (fileName, date)
	}

	/// Every workspace still on disk, newest first.
	static func recents() -> [IPAWorkspaceRecord] {
		let fileManager = FileManager.default
		let urls = (try? fileManager.contentsOfDirectory(
			at: root,
			includingPropertiesForKeys: [.contentModificationDateKey],
			options: [.skipsHiddenFiles]
		)) ?? []

		return urls.compactMap { url -> IPAWorkspaceRecord? in
			guard let metadata = metadata(at: url) else { return nil }
			let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? metadata.date
			return IPAWorkspaceRecord(
				id: url.lastPathComponent,
				name: metadata.fileName,
				date: date,
				isLibraryApp: false
			)
		}
		.sorted { $0.date > $1.date }
	}

	/// Removes every workspace (used by Reset and the home screen's "Clear" action).
	static func discardAll() {
		try? FileManager.default.removeItem(at: root)
	}

	private static func findApp(in directory: URL) -> URL? {
		let fileManager = FileManager.default

		func firstApp(_ url: URL) -> URL? {
			let contents = (try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
			return contents.first { $0.pathExtension.lowercased() == "app" && (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
		}

		let payload = directory.appendingPathComponent("Payload", isDirectory: true)
		if let app = firstApp(payload) { return app }
		if let app = firstApp(directory) { return app }

		// Fall back to a shallow search — some archives nest the payload a level down.
		guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
			return nil
		}

		for case let url as URL in enumerator where url.pathExtension.lowercased() == "app" {
			if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
				return url
			}
		}

		return nil
	}

	private static func unzip(_ archive: URL, to destination: URL) async throws {
		try ArchiveSafetyValidator.validate(archive, destination: destination)
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
			DispatchQueue.global(qos: .userInitiated).async {
				do {
					try Zip.unzipFile(archive, destination: destination, overwrite: true, password: nil, progress: nil)
					continuation.resume()
				} catch {
					continuation.resume(throwing: error)
				}
			}
		}
	}
}
