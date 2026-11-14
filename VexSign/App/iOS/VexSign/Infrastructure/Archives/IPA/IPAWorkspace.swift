//
//  IPAWorkspace.swift
//  VexSign
//
//  Opens an IPA (or a library app) as a browsable, editable working copy and puts it back
//  together again. This is the engine behind the IPA Explorer.
//

import Foundation
import SwiftUI
import NimbleExtensions

// MARK: - Errors
enum IPAWorkspaceError: LocalizedError {
	case payloadNotFound
	case appNotFound
	case extractionFailed(String)
	case rebuildFailed(String)
	case empty
	case noCertificate
	case undoBackupFailed

	var errorDescription: String? {
		switch self {
		case .payloadNotFound:	.localized("No Payload folder was found inside this IPA. It may not be an app archive.")
		case .appNotFound:		.localized("No .app bundle was found inside the Payload folder.")
		case .extractionFailed(let reason):	.localized("The IPA could not be opened: %@", arguments: reason)
		case .rebuildFailed(let reason):	.localized("The IPA could not be rebuilt: %@", arguments: reason)
		case .empty:			.localized("Nothing to save yet.")
		case .noCertificate:	.localized("Signing needs a certificate. Import one in Settings → Certificates, or sign with the default signing option.")
		case .undoBackupFailed:	.localized("This file could not be backed up, so the change was not made.")
		}
	}
}

// MARK: - Record
/// One workspace on disk, used for the "Recent" list on the explorer's home screen.
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
    @Published private(set) var totalSize: Int64 = 0
    private var sizeObservation: Task<Void, Never>?
    private var sizeGeneration = UUID()
    private var rebuildGeneration: UUID?

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
        refreshSize()
	}

    deinit { sizeObservation?.cancel() }

    /// One debounced background sample per edit, not one recursive scan for
    /// every progress publication. A superseded sample can never replace it.
    private func refreshSize() {
        sizeObservation?.cancel()
        let root = containerURL
        let generation = UUID()
        sizeGeneration = generation
        sizeObservation = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(120))
                let worker = Task.detached(priority: .utility) {
                    try Task.checkCancellation()
                    let bytes = FileManager.default.allocatedSize(at: root)
                    try Task.checkCancellation()
                    return bytes
                }
                let bytes = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard let self, self.sizeGeneration == generation else { return }
                self.totalSize = bytes
            } catch is CancellationError {
                // A stale header sample has no effect on the workspace.
            } catch {
                FileLogger.error("Could not sample archive workspace size.", category: "files")
            }
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

	// MARK: Opening

	/// Extracts an IPA into a fresh workspace. The original file is only read.
	static func open(ipa url: URL) async throws -> IPAWorkspace {
        try Task.checkCancellation()
        let lease = try AppOperationRegistry.shared.acquireTemporaryWork()
        defer { withExtendedLifetime(lease) {} }
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
            let worker = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                try FileManager.default.copyItem(at: url, to: localCopy)
                try Task.checkCancellation()
            }
            try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: { worker.cancel() }
            try Task.checkCancellation()

			let destination = workspaceRoot.appendingPathComponent("Extracted", isDirectory: true)
			try fileManager.createDirectoryIfNeeded(at: destination)

			try await unzip(localCopy, to: destination)
            try Task.checkCancellation()
			try? fileManager.removeItem(at: localCopy) // try? ok: best-effort workspace cleanup

			guard let appURL = findApp(in: destination) else {
				try? fileManager.removeItem(at: workspaceRoot) // try? ok: best-effort workspace cleanup
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
        } catch is CancellationError {
            try? fileManager.removeItem(at: workspaceRoot) // try? ok: best-effort workspace cleanup after the worker exits
            throw CancellationError()
		} catch let error as IPAWorkspaceError {
			try? fileManager.removeItem(at: workspaceRoot) // try? ok: best-effort workspace cleanup
			throw error
		} catch {
			try? fileManager.removeItem(at: workspaceRoot) // try? ok: best-effort workspace cleanup
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

	/// Acquire immediately before touching bundle bytes, not when an editor opens.
	/// The lease must remain alive through the entire write (or detached packaging worker).
	func acquireEditingLease() throws -> AppOperationRegistry.Lease {
		guard !isBusy else { throw AppOperationRegistry.Busy() }
		let key: String
		switch source {
		case .libraryApp(let uuid, let isSigned):
			guard !uuid.isEmpty else { throw IPAWorkspaceError.appNotFound }
			key = "\(isSigned ? "signed" : "imported"):\(uuid)"
		case .archive:
			key = "workspace:\(id)"
		}
		let lease = try AppOperationRegistry.shared.acquire(key)
		// A workspace can outlive a deletion. Never recreate a deleted library copy.
		var isDirectory: ObjCBool = false
		guard _fileManager.fileExists(atPath: appURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
			throw IPAWorkspaceError.appNotFound
		}
		return lease
	}

	/// Records an edit so the explorer can warn before dropping unsaved archive changes.
	func markDirty() {
		changeCount += 1
		lastError = nil
        refreshSize()
		objectWillChange.send()
	}

	func clearDirty() {
		changeCount = 0
	}

	// MARK: Undo journal

	/// Backs up `url` before a destructive edit. Library workspaces have no undo
	/// journal; archive workspaces must have a durable backup or the edit is refused.
	func backupForUndo(_ url: URL) throws -> String? {
		guard let journal else { return nil }
		guard let backupName = journal.backup(at: url, container: containerURL) else {
			throw IPAWorkspaceError.undoBackupFailed
		}
		return backupName
	}

	func discardUndoBackup(_ backupName: String?) {
		journal?.discardBackup(backupName)
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
        try Task.checkCancellation()
        let lease = try acquireEditingLease()
        defer { withExtendedLifetime(lease) {} }
        let invocation = UUID()
        rebuildGeneration = invocation
        isBusy = true
        progress = 0
        lastError = nil
        defer {
            rebuildGeneration = nil
            isBusy = false
            progress = 0
        }

        let target = destination ?? defaultArchiveURL()
        let staging = target.deletingLastPathComponent().appendingPathComponent(".VexSignRebuild_\(UUID().uuidString)", isDirectory: true)
        let stagedArchive = staging.appendingPathComponent("Archive.ipa")
        let payload = containerURL.appendingPathComponent("Payload", isDirectory: true)
        let sourceApp = appURL
        let compression = ArchiveCompression.allCases[safe: ArchiveHandler.getCompressionLevel()] ?? .defaultCompression
        defer {
            // Both the wrapping parent and a failed zip/IPA belong to this run.
            // Never remove the user's existing export to clean a failed attempt.
            if _fileManager.fileExists(atPath: staging.path) {
                do { try _fileManager.removeItem(at: staging) }
                catch { FileLogger.error("Could not remove archive export staging.", category: "files") }
            }
        }
        do {
            let worker = Task.detached(priority: .userInitiated) { [weak self] in
                try Task.checkCancellation()
                let manager = FileManager.default
                try manager.createDirectory(at: staging, withIntermediateDirectories: true)
                let packaged: URL
                if manager.fileExists(atPath: payload.path) {
                    packaged = payload
                } else {
                    packaged = staging.appendingPathComponent("Payload", isDirectory: true)
                    try manager.createDirectory(at: packaged, withIntermediateDirectories: true)
                    try manager.copyItem(at: sourceApp, to: packaged.appendingPathComponent(sourceApp.lastPathComponent))
                }
                try Task.checkCancellation()
                let gate = ProgressGate()
                try AppArchiver.zip(payload: packaged, to: stagedArchive, compression: compression) { value in
                    guard gate.admit(value) else { return }
                    Task { @MainActor [weak self] in
                        guard let self, self.rebuildGeneration == invocation, self.isBusy else { return }
                        self.progress = max(self.progress, min(max(value, 0), 1))
                    }
                }
                try Task.checkCancellation()
            }
            // Waiting for the worker even after cancellation keeps the source
            // lease, destination ownership and cleanup in one lifetime.
            try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            if _fileManager.fileExists(atPath: target.path) {
                _ = try _fileManager.replaceItemAt(target, withItemAt: stagedArchive)
            } else {
                try _fileManager.moveItem(at: stagedArchive, to: target)
            }
            builtArchive = target
            changeCount = 0
            journal?.clearAll()
            refreshSize()
            return target
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            lastError = error.localizedDescription
            throw IPAWorkspaceError.rebuildFailed(error.localizedDescription)
        }
	}

	/// Where "Save IPA" lands: `Documents/Archives/<name>_<timestamp>.ipa`.
	func defaultArchiveURL() -> URL {
		let stamp = Int(Date().timeIntervalSince1970)
		let safeName = name.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: "_")
		let base = safeName.isEmpty ? "App" : safeName
		return _fileManager.archives.appendingPathComponent("\(base)_edited_\(stamp)_\(UUID().uuidString.prefix(8)).ipa")
	}

	/// Imports the rebuilt IPA back into the library through the normal import pipeline.
	func importIntoLibrary() async throws -> AppInfoPresentable {
		let ipa = try await rebuild()

        try Task.checkCancellation()
        let cancellation = BackgroundWorkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AppInfoPresentable, Error>) in
                let worker = PackageImportService.importPackage(ipa) { result in continuation.resume(with: result) }
                cancellation.adopt(worker)
            }
        } onCancel: { cancellation.cancel() }
	}

	/// The library app this workspace edits, when it is one.
	var libraryApp: AppInfoPresentable? {
		guard case .libraryApp(let uuid, let isSigned) = source else { return nil }
        return Storage.shared.getAllApps().first { $0.uuid == uuid && $0.isSigned == isSigned }
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

        do { try Task.checkCancellation() }
        catch {
            if temporary { Storage.shared.deleteApp(for: target) }
            throw error
        }
		let certificate = Storage.shared.getCertificate(for: UserDefaults.standard.integer(forKey: "vexsign.selectedCert"))
		let options = OptionsManager.shared.options.resolved(for: target)

		guard options.signingOption != .default || certificate != nil else {
			if temporary { Storage.shared.deleteApp(for: target) }
			throw IPAWorkspaceError.noCertificate
		}

		let signed: Signed
        let requestID = UUID().uuidString
        let cancellation = BackgroundWorkCompletionFlag()
		do {
            signed = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Signed, Error>) in
                    PackageSigningCoordinator.signPackage(target, using: options, icon: nil, certificate: certificate,
                        requestID: requestID, isCancellationRequested: { cancellation.isSet }) { result in
                        continuation.resume(with: result)
                    }
                }
            } onCancel: {
                cancellation.set()
                Task { @MainActor in SigningService.shared.cancel(requestID) }
            }
		} catch {
			if temporary { Storage.shared.deleteApp(for: target) }
			throw error
		}

        // Cancellation after artifact commit keeps the output, but must never
        // submit a fresh installation behind a dismissed explorer.
        guard !Task.isCancelled else {
            if temporary { Storage.shared.deleteApp(for: target) }
            throw CancellationError()
        }
		// The copy that was signed is done either way: a re-sign replaces the old entry, an
		// import only existed to be signed. It is removed once the signed copy is confirmed to be
		// in the library; if that cannot be confirmed, or the copy is in use, it stays.
		CleanupManager.shared.finishSign(source: target, output: signed, origin: .explorer, sweepsStorage: false)

		InstallQueue.shared.enqueue(signed)
		return signed
	}

	/// Deletes the workspace's temporary files. Library apps are never touched.
	func discard() {
		guard !isLibraryApp else { return }
		try? _fileManager.removeItem(at: Self.root.appendingPathComponent(id, isDirectory: true)) // try? ok: best-effort workspace cleanup
	}

	// MARK: Filesystem


	private func _writeMetadata() {
		let metadata: [String: Any] = [
			"fileName": sourceDescription,
			"date": Date().timeIntervalSince1970,
			"name": name
		]
		let url = Self.root.appendingPathComponent(id, isDirectory: true).appendingPathComponent(".workspace.json")
		try? JSONSerialization.data(withJSONObject: metadata, options: .prettyPrinted).write(to: url) // try? ok: best-effort workspace metadata; the workspace stays usable without it
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
			let data = try? Data(contentsOf: directory.appendingPathComponent(".workspace.json")), // try? ok: optional workspace metadata read
			let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], // try? ok: optional workspace metadata read
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
		let urls = (try? fileManager.contentsOfDirectory( // try? ok: best-effort workspace listing
			at: root,
			includingPropertiesForKeys: [.contentModificationDateKey],
			options: [.skipsHiddenFiles]
		)) ?? []

		return urls.compactMap { url -> IPAWorkspaceRecord? in
			guard let metadata = metadata(at: url) else { return nil }
			let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? metadata.date // try? ok: best-effort modification date; fall back to metadata
			return IPAWorkspaceRecord(
				id: url.lastPathComponent,
				name: metadata.fileName,
				date: date,
				isLibraryApp: false, url: url
			)
		}
		.sorted { $0.date > $1.date }
	}

	/// Removes every workspace (used by Reset and the home screen's "Clear" action).
	static func discardAll() throws {
        guard let lease = AppOperationRegistry.shared.acquireCleanup() else { throw AppOperationRegistry.Busy() }
        defer { withExtendedLifetime(lease) {} }
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
	}

	private static func findApp(in directory: URL) -> URL? {
		let fileManager = FileManager.default

		func firstApp(_ url: URL) -> URL? {
			let contents = (try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [] // try? ok: best-effort app-bundle discovery
			return contents.first { $0.pathExtension.lowercased() == "app" && (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true } // try? ok: best-effort app-bundle discovery
		}

		let payload = directory.appendingPathComponent("Payload", isDirectory: true)
		if let app = firstApp(payload) { return app }
		if let app = firstApp(directory) { return app }

		// Fall back to a shallow search — some archives nest the payload a level down.
		guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
			return nil
		}

		for case let url as URL in enumerator where url.pathExtension.lowercased() == "app" {
			if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { // try? ok: best-effort directory probe
				return url
			}
		}

		return nil
	}

	private static func unzip(_ archive: URL, to destination: URL) async throws {
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            // The extractor validates and checkpoints every file/chunk.
            try IPAExtractor.extract(archive, to: destination)
            try Task.checkCancellation()
        }
        try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
        try Task.checkCancellation()
	}
}

// Compatibility initializer for persistence fixtures and internal callers.
extension IPAWorkspaceRecord {
    init(id: String, name: String, date: Date, isLibraryApp: Bool) {
        self.init(id: id, name: name, date: date, isLibraryApp: isLibraryApp,
            url: IPAWorkspace.root.appendingPathComponent(id, isDirectory: true))
    }
}
