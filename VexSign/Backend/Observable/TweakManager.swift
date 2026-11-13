//
//  TweakManager.swift
//  VexSign
//
//  Library of reusable tweaks (.dylib/.deb/.framework/.bundle) with versions and
//  auto-inject rules. Persisted as a JSON manifest, not CoreData, to stay clear of
//  the CoreData store's destroy-and-recreate corruption fallback.
//

import Foundation
import NimbleExtensions
import OSLog

// MARK: - Models

final class TweakManager: ObservableObject {
	static let shared = TweakManager()

	@Published private(set) var tweaks: [ManagedTweak]
	@Published private(set) var folders: [TweakFolder]
	@Published private(set) var repositories: [TweakRepository]

	private let _fm = FileManager.default
	@MainActor private var _isImportingRepository = false
	private var _manifestURL: URL { _fm.tweaksLibrary.appendingPathComponent("library.json") }
	private var _foldersURL: URL { _fm.tweaksLibrary.appendingPathComponent("folders.json") }
	private var _repositoriesURL: URL { _fm.tweaksLibrary.appendingPathComponent("repositories.json") }

	private init() {
		self.tweaks = []
		self.folders = []
		self.repositories = []
		_load()
		_loadFolders()
		_loadRepositories()
	}

	// MARK: Persistence

	private func _load() {
		guard let data = try? Data(contentsOf: _manifestURL) else { return } // try? ok: optional manifest; a missing file is an empty library
		self.tweaks = TweakManager.decodeLenientArray(ManagedTweak.self, from: data)
	}

	private func _save() {
		do {
			try _fm.createDirectoryIfNeeded(at: _fm.tweaksLibrary)
			let encoder = JSONEncoder()
			encoder.outputFormatting = [.prettyPrinted]
			let data = try encoder.encode(tweaks)
			try data.write(to: _manifestURL, options: .atomic)
		} catch {
			Logger.misc.error("TweakManager save failed: \(error.localizedDescription)")
		}
		objectWillChange.send()
	}

	private func _loadFolders() {
		guard let data = try? Data(contentsOf: _foldersURL) else { return } // try? ok: optional folders file; a missing file means no folders
		self.folders = TweakManager.decodeLenientArray(TweakFolder.self, from: data)
	}

	private func _saveFolders() {
		do {
			try _fm.createDirectoryIfNeeded(at: _fm.tweaksLibrary)
			let encoder = JSONEncoder()
			encoder.outputFormatting = [.prettyPrinted]
			let data = try encoder.encode(folders)
			try data.write(to: _foldersURL, options: .atomic)
		} catch {
			Logger.misc.error("TweakManager folders save failed: \(error.localizedDescription)")
		}
		objectWillChange.send()
	}

	private func _loadRepositories() {
		guard let data = try? Data(contentsOf: _repositoriesURL) else { return } // try? ok: optional repositories file; a missing file means no repositories
		repositories = TweakManager.decodeLenientArray(TweakRepository.self, from: data)
	}

	private func _saveRepositories() {
		do {
			try _fm.createDirectoryIfNeeded(at: _fm.tweaksLibrary)
			let data = try JSONEncoder().encode(repositories)
			try data.write(to: _repositoriesURL, options: .atomic)
		} catch {
			Logger.misc.error("TweakManager repositories save failed: \(error.localizedDescription)")
		}
		objectWillChange.send()
	}

	// MARK: Folders

	/// Tweaks in the given folder (`nil` = uncategorized).
	func tweaks(inFolder folderId: UUID?) -> [ManagedTweak] {
		tweaks.filter { $0.folderId == folderId }
	}

	func tweakCount(inFolder folderId: UUID?) -> Int {
		tweaks.reduce(0) { $0 + ($1.folderId == folderId ? 1 : 0) }
	}

	func folder(_ id: UUID?) -> TweakFolder? {
		guard let id else { return nil }
		return folders.first { $0.id == id }
	}

	@discardableResult
	func addFolder(name: String) -> TweakFolder {
		let folder = TweakFolder(name: _uniqueFolderName(name))
		folders.append(folder)
		_saveFolders()
		return folder
	}

	func renameFolder(_ id: UUID, to name: String) {
		guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
		let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return }
		folders[index].name = _uniqueFolderName(trimmed, excluding: id)
		_saveFolders()
	}

	/// Unique folder name among siblings, appending " 2", " 3"… on collision.
	private func _uniqueFolderName(_ desired: String, excluding id: UUID? = nil) -> String {
		var base = desired.trimmingCharacters(in: .whitespacesAndNewlines)
		if base.isEmpty { base = .localized("New Folder") }
		let taken = Set(folders.filter { $0.id != id }.map { $0.name.lowercased() })
		guard taken.contains(base.lowercased()) else { return base }
		var n = 2
		while taken.contains("\(base) \(n)".lowercased()) { n += 1 }
		return "\(base) \(n)"
	}

	/// Deletes a folder; its tweaks fall back to uncategorized (never deleted).
	func deleteFolder(_ id: UUID) {
		var touched = false
		for index in tweaks.indices where tweaks[index].folderId == id {
			tweaks[index].folderId = nil
			touched = true
		}
		folders.removeAll { $0.id == id }
		if touched { _save() }
		_saveFolders()
	}

	/// Moves tweaks into a folder (`nil` = uncategorized).
	func moveTweaks(_ ids: Set<UUID>, toFolder folderId: UUID?) {
		var touched = false
		for index in tweaks.indices where ids.contains(tweaks[index].id) {
			tweaks[index].folderId = folderId
			touched = true
		}
		if touched { _save() }
	}

	// MARK: Disk layout

	/// `Documents/Tweaks/<tweakID>/<versionID>/`
	func versionDirectory(forTweak tweakId: UUID, version: TweakVersion) -> URL {
		_fm.tweaksLibrary(tweakId.uuidString).appendingPathComponent(version.id.uuidString)
	}

	func fileURL(forTweak tweakId: UUID, version: TweakVersion, component: TweakComponent) -> URL {
		versionDirectory(forTweak: tweakId, version: version)
			.appendingPathComponent(component.fileName)
	}

	func fileURL(forTweak tweak: ManagedTweak, version: TweakVersion, component: TweakComponent) -> URL {
		fileURL(forTweak: tweak.id, version: version, component: component)
	}

	func fileURLs(forTweak tweakId: UUID, version: TweakVersion) -> [URL] {
		version.components.map { fileURL(forTweak: tweakId, version: version, component: $0) }
	}

	// MARK: Tweak repositories

	/// Adds a small JSON feed and imports its downloadable tweak components. Supported
	/// entries use `name` plus `url`, `download`, or `downloadURL`; a root object may
	/// place entries under `tweaks`, `packages`, or `items`.
	@MainActor
	func addRepository(_ url: URL) async throws -> Int {
        let workLease = try AppOperationRegistry.shared.acquireTemporaryWork()
        defer { withExtendedLifetime(workLease) {} }
		guard !_isImportingRepository else { throw RepositoryError.invalid("Another tweak repository import is already running.") }
		_isImportingRepository = true
		defer { _isImportingRepository = false }
		guard url.scheme?.lowercased() == "https" else {
			throw RepositoryError.invalid("Tweak repositories must use HTTPS.")
		}
		// Download to disk: checking Data.count only after URLSession.data allocates the
		// entire untrusted response can terminate the app before the limit is checked.
		let feed = try await _downloadRepositoryFile(url, maximumBytes: 5 * 1_024 * 1_024)
		defer { _removeRepositoryDownload(feed) }
		let data = try Data(contentsOf: feed)
		guard let object = try? JSONSerialization.jsonObject(with: data) else { // try? ok: decode failure is surfaced as RepositoryError.invalid below
			throw RepositoryError.invalid("The tweak repository is not valid JSON.")
		}

		let entries: [[String: Any]]
		if let array = object as? [[String: Any]] {
			entries = array
		} else if let dictionary = object as? [String: Any],
				  let nested = ["tweaks", "packages", "items"].compactMap({ dictionary[$0] as? [[String: Any]] }).first {
			entries = nested
		} else {
			throw RepositoryError.invalid("No tweak entries were found in this repository.")
		}

		let repositoryID = repositories.first(where: { $0.url == url })?.id ?? UUID()
		let repositoryName = (object as? [String: Any])?["name"] as? String
			?? url.host
			?? url.deletingPathExtension().lastPathComponent
		let storage = _fm.tweaksLibrary.appendingPathComponent("Repositories", isDirectory: true)
			.appendingPathComponent(repositoryID.uuidString, isDirectory: true)
		try _fm.createDirectory(at: storage, withIntermediateDirectories: true)

		var imported = 0
		for entry in entries.prefix(100) {
			guard
				let rawURL = (entry["url"] as? String)
					?? (entry["download"] as? String)
					?? (entry["downloadURL"] as? String),
				let downloadURL = URL(string: rawURL, relativeTo: url)?.absoluteURL,
				downloadURL.scheme?.lowercased() == "https"
			else { continue }

			try Task.checkCancellation()
			let ext = downloadURL.pathExtension.isEmpty ? "dylib" : downloadURL.pathExtension.lowercased()
			guard ["dylib", "deb"].contains(ext),
				  let filename = TweakImportSupport.repositoryFilename(for: downloadURL) else { continue }
			let downloaded = try await _downloadRepositoryFile(downloadURL, maximumBytes: 100 * 1_024 * 1_024)
			defer { _removeRepositoryDownload(downloaded) }
			// Preserve legitimate library names (dependencies may refer to them), but
			// isolate every download and never use a feed's display name as a path.
			let work = storage.appendingPathComponent(UUID().uuidString, isDirectory: true)
			try _fm.createDirectory(at: work, withIntermediateDirectories: true)
			defer { _removeRepositoryDownload(work) }
			let fileURL = work.appendingPathComponent(filename)
			try _fm.moveItem(at: downloaded, to: fileURL)
			let displayName = (entry["name"] as? String) ?? downloadURL.deletingPathExtension().lastPathComponent
			if await importTweak(name: displayName, fromFiles: [fileURL], versionLabel: (entry["version"] as? String) ?? "1.0") != nil {
				imported += 1
			}
		}

		guard imported > 0 else { throw RepositoryError.invalid("No supported tweaks could be imported from this repository.") }
		if let index = repositories.firstIndex(where: { $0.url == url }) {
			repositories[index].name = repositoryName
			repositories[index].lastFetched = Date()
			repositories[index].importedCount += imported
		} else {
			repositories.append(TweakRepository(id: repositoryID, name: repositoryName, url: url, lastFetched: Date(), importedCount: imported))
		}
		_saveRepositories()
		return imported
	}

	/// Disk-backed transport avoids response-sized RAM allocations. Cancel oversized
	/// transfers during progress, then recheck the completed temporary file.
	private func _downloadRepositoryFile(_ url: URL, maximumBytes: Int) async throws -> URL {
		let limit = TweakImportSupport.DownloadLimit(maximumBytes: Int64(maximumBytes))
		let (file, response) = try await URLSession.shared.download(from: url, delegate: limit)
		do {
			try Task.checkCancellation()
			guard let http = response as? HTTPURLResponse,
				  http.url?.scheme?.lowercased() == "https",
				  (200..<300).contains(http.statusCode) else {
				throw RepositoryError.invalid("The tweak repository download failed or redirected to an insecure URL.")
			}
			let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
			guard values.isRegularFile == true, let bytes = values.fileSize,
				  bytes > 0, bytes <= maximumBytes else {
				throw RepositoryError.invalid("The tweak repository download is empty or exceeds its size limit.")
			}
			return file
		} catch {
			_removeRepositoryDownload(file)
			throw error
		}
	}

	private func _removeRepositoryDownload(_ file: URL) {
		guard _fm.fileExists(atPath: file.path) else { return }
		do { try _fm.removeItem(at: file) }
		catch { FileLogger.error("Could not remove repository download: \(error)", category: "tweaks") }
	}

	@MainActor
	func removeRepository(_ id: UUID) {
		repositories.removeAll { $0.id == id }
		_saveRepositories()
	}

	// MARK: Mutations

	@discardableResult
	func addTweak(name: String, from fileURL: URL, versionLabel: String = "1.0") -> ManagedTweak? {
		addTweak(name: name, fromFiles: [fileURL], versionLabel: versionLabel)
	}

	/// Imports several picked files as one tweak (a multi-file version).
	@discardableResult
	func addTweak(name: String, fromFiles fileURLs: [URL], versionLabel: String = "1.0") -> ManagedTweak? {
		guard let first = fileURLs.first else { return nil }
		let tweakId = UUID()
		let versionId = UUID()
		let stored = _storeComponents(fileURLs, forTweak: tweakId, versionId: versionId, existing: [])
		guard !stored.isEmpty else { return nil }

		let tweak = ManagedTweak(
			id: tweakId,
			name: name.isEmpty ? first.deletingPathExtension().lastPathComponent : name,
			versions: [TweakVersion(id: versionId, label: versionLabel, components: stored)],
			selectedVersionId: versionId
		)
		tweaks.insert(tweak, at: 0)
		_save()
		return tweak
	}

	@discardableResult
	func addVersion(to tweakId: UUID, from fileURL: URL, label: String) -> TweakVersion? {
		addVersion(to: tweakId, fromFiles: [fileURL], label: label)
	}

	/// Adds another version (one or more files) to an existing tweak.
	@discardableResult
	func addVersion(to tweakId: UUID, fromFiles fileURLs: [URL], label: String) -> TweakVersion? {
		guard let index = tweaks.firstIndex(where: { $0.id == tweakId }) else { return nil }
		let versionId = UUID()
		let stored = _storeComponents(fileURLs, forTweak: tweakId, versionId: versionId, existing: [])
		guard !stored.isEmpty else { return nil }

		let version = TweakVersion(id: versionId, label: label, components: stored)
		tweaks[index].versions.append(version)
		tweaks[index].selectedVersionId = versionId
		_save()
		return version
	}

	@discardableResult
	func addComponents(to tweakId: UUID, versionId: UUID, fromFiles fileURLs: [URL]) -> [TweakComponent] {
		guard
			let tIndex = tweaks.firstIndex(where: { $0.id == tweakId }),
			let vIndex = tweaks[tIndex].versions.firstIndex(where: { $0.id == versionId })
		else { return [] }

		let existing = tweaks[tIndex].versions[vIndex].components
		let stored = _storeComponents(fileURLs, forTweak: tweakId, versionId: versionId, existing: existing)
		guard !stored.isEmpty else { return [] }

		tweaks[tIndex].versions[vIndex].components.append(contentsOf: stored)
		_save()
		return stored
	}

    @MainActor
    private func _prepareImport(_ sources: [URL]) async -> TweakImportSupport.PreparedVersion? {
        do { return try await TweakImportSupport.prepareVersion(sources) }
        catch {
            FileLogger.error("Tweak import preparation failed: \(error.localizedDescription)", category: "tweaks")
            return nil
        }
    }

    @MainActor
    private func _commitVersion(_ prepared: TweakImportSupport.PreparedVersion, tweakId: UUID, versionId: UUID) -> [TweakComponent]? {
        let parent = _fm.tweaksLibrary(tweakId.uuidString)
        do {
            try Task.checkCancellation()
            try _fm.createDirectory(at: parent, withIntermediateDirectories: true)
            try _fm.moveItem(at: prepared.directory, to: parent.appendingPathComponent(versionId.uuidString))
            return prepared.files.map { TweakComponent(fileName: $0.name, fileType: TweakFileType(fileExtension: URL(fileURLWithPath: $0.name).pathExtension), fileSize: $0.size) }
        } catch {
            FileLogger.error("Tweak import commit failed: \(error.localizedDescription)", category: "tweaks")
            return nil
        }
    }

    @MainActor
    func importTweak(name: String, fromFiles sources: [URL], versionLabel: String = "1.0") async -> ManagedTweak? {
        guard !sources.isEmpty, let prepared = await _prepareImport(sources) else { return nil }
        defer { TweakImportSupport.discardPrepared(prepared) }
        let tweakId = UUID(), versionId = UUID()
        guard let files = _commitVersion(prepared, tweakId: tweakId, versionId: versionId), !files.isEmpty else { return nil }
        let tweak = ManagedTweak(id: tweakId, name: name.isEmpty ? sources[0].deletingPathExtension().lastPathComponent : name,
            versions: [TweakVersion(id: versionId, label: versionLabel, components: files)], selectedVersionId: versionId)
        tweaks.insert(tweak, at: 0)
        _save()
        return tweak
    }

    @MainActor
    func importVersion(to tweakId: UUID, fromFiles sources: [URL], label: String) async -> TweakVersion? {
        guard !sources.isEmpty, tweak(tweakId) != nil, let prepared = await _prepareImport(sources) else { return nil }
        defer { TweakImportSupport.discardPrepared(prepared) }
        // Do not retain array indices across suspension: the user may delete/reorder rows.
        guard let index = tweaks.firstIndex(where: { $0.id == tweakId }) else { return nil }
        let versionId = UUID()
        guard let files = _commitVersion(prepared, tweakId: tweakId, versionId: versionId) else { return nil }
        let version = TweakVersion(id: versionId, label: label, components: files)
        tweaks[index].versions.append(version)
        tweaks[index].selectedVersionId = versionId
        _save()
        return version
    }

    @MainActor
    func importComponents(to tweakId: UUID, versionId: UUID, fromFiles sources: [URL]) async -> [TweakComponent] {
        guard !sources.isEmpty, let prepared = await _prepareImport(sources) else { return [] }
        defer { TweakImportSupport.discardPrepared(prepared) }
        guard !Task.isCancelled,
              let index = tweaks.firstIndex(where: { $0.id == tweakId }),
              let versionIndex = tweaks[index].versions.firstIndex(where: { $0.id == versionId }) else { return [] }
        let destination = _fm.tweaksLibrary(tweakId.uuidString).appendingPathComponent(versionId.uuidString)
        var taken = Set(tweaks[index].versions[versionIndex].components.map { $0.fileName.lowercased() })
        var added: [TweakComponent] = []
        for file in prepared.files {
            let name = _uniqueFileName(file.name, taken: taken)
            do {
                try _fm.moveItem(at: prepared.directory.appendingPathComponent(file.name), to: destination.appendingPathComponent(name))
                taken.insert(name.lowercased())
                added.append(TweakComponent(fileName: name, fileType: TweakFileType(fileExtension: URL(fileURLWithPath: name).pathExtension), fileSize: file.size))
            } catch { FileLogger.error("Tweak component commit failed: \(error)", category: "tweaks") }
        }
        tweaks[index].versions[versionIndex].components.append(contentsOf: added)
        _save()
        return added
    }

	/// Removes a component (and its file); removing the last one deletes the version.
	func deleteComponent(_ componentId: UUID, versionId: UUID, from tweakId: UUID) {
		guard
			let tIndex = tweaks.firstIndex(where: { $0.id == tweakId }),
			let vIndex = tweaks[tIndex].versions.firstIndex(where: { $0.id == versionId }),
			let component = tweaks[tIndex].versions[vIndex].components.first(where: { $0.id == componentId })
		else { return }

		let version = tweaks[tIndex].versions[vIndex]
		try? _fm.removeFileIfNeeded(at: fileURL(forTweak: tweakId, version: version, component: component)) // try? ok: best-effort disk cleanup; the in-memory library is authoritative
		tweaks[tIndex].versions[vIndex].components.removeAll { $0.id == componentId }

		if tweaks[tIndex].versions[vIndex].components.isEmpty {
			deleteVersion(versionId, from: tweakId)
		} else {
			_save()
		}
	}

	func mutateComponent(_ componentId: UUID, versionId: UUID, in tweakId: UUID, _ change: (inout TweakComponent) -> Void) {
		guard
			let tIndex = tweaks.firstIndex(where: { $0.id == tweakId }),
			let vIndex = tweaks[tIndex].versions.firstIndex(where: { $0.id == versionId }),
			let cIndex = tweaks[tIndex].versions[vIndex].components.firstIndex(where: { $0.id == componentId })
		else { return }
		change(&tweaks[tIndex].versions[vIndex].components[cIndex])
		_save()
	}

	func deleteTweak(_ id: UUID) {
		guard let index = tweaks.firstIndex(where: { $0.id == id }) else { return }
		try? _fm.removeFileIfNeeded(at: _fm.tweaksLibrary(id.uuidString)) // try? ok: best-effort disk cleanup; the in-memory library is authoritative
		tweaks.remove(at: index)
		_save()
	}

	/// Single batched mutation — deleting one-by-one fired `tweaks` (+ `.animation`)
	/// repeatedly mid-edit and crashed the list diff.
	func deleteTweaks(_ ids: Set<UUID>) {
		guard !ids.isEmpty else { return }
		for id in ids {
			try? _fm.removeFileIfNeeded(at: _fm.tweaksLibrary(id.uuidString)) // try? ok: best-effort disk cleanup; the in-memory library is authoritative
		}
		tweaks.removeAll { ids.contains($0.id) }
		_save()
	}

	/// Deletes tweaks and offers Undo. Each tweak's files are moved aside rather than
	/// erased, and the tweak is put back at its old position if the user undoes it. A tweak
	/// whose files cannot be set aside is still deleted, just without being restorable.
	func deleteTweaksOfferingUndo(_ ids: Set<UUID>) {
		let removed = tweaks.enumerated().filter { ids.contains($0.element.id) }
		guard !removed.isEmpty else { return }

		var tokens: [UUID: RecoverableFileRemoval.Token] = [:]
		var restorable: [(offset: Int, tweak: ManagedTweak)] = []
		for (offset, tweak) in removed {
			let folder = _fm.tweaksLibrary(tweak.id.uuidString)
			if _fm.fileExists(atPath: folder.path) {
				do {
					tokens[tweak.id] = try RecoverableFileRemoval.remove(folder)
				} catch {
					Logger.misc.error("Tweak files could not be set aside; deleting without Undo.")
					continue
				}
			}
			restorable.append((offset, tweak))
		}

		deleteTweaks(ids)
		guard let first = restorable.first else { return }

		UndoableRemoval.announce(UndoableRemoval(
			title: restorable.count == 1 ? first.tweak.name : String.localized("%lld tweaks", arguments: restorable.count),
			restore: { [weak self] in
				guard let self else { return false }
				return self._restoreTweaks(restorable, tokens: tokens)
			},
			discard: { tokens.values.forEach { RecoverableFileRemoval.discard($0) } }
		))
	}

	private func _restoreTweaks(
		_ removed: [(offset: Int, tweak: ManagedTweak)],
		tokens: [UUID: RecoverableFileRemoval.Token]
	) -> Bool {
		var restoredAny = false
		for (offset, tweak) in removed.sorted(by: { $0.offset < $1.offset }) {
			guard !tweaks.contains(where: { $0.id == tweak.id }) else { continue }
			if let token = tokens[tweak.id] {
				do {
					try RecoverableFileRemoval.restore(token)
				} catch {
					Toast.error(error.localizedDescription)
					continue
				}
			}
			tweaks.insert(tweak, at: min(offset, tweaks.count))
			restoredAny = true
		}
		if restoredAny { _save() }
		return restoredAny
	}

	/// Each manifest commits separately. A failure may leave earlier folders restored.
	@discardableResult
	func mergeFromBackup(tweaksDir: URL) throws -> Int {
		try TweakBackupMerge.run(source: tweaksDir, destination: _fm.tweaksLibrary,
			currentTweaks: tweaks, currentFolders: folders,
			onFoldersCommitted: { self.folders = $0 },
			onTweaksCommitted: { self.tweaks = $0 })
	}

	/// Wipes the entire tweak library — all tweaks, folders, and files on disk.
	func resetLibrary() {
		tweaks = []
		folders = []
		repositories = []
		try? _fm.removeFileIfNeeded(at: _fm.tweaksLibrary) // try? ok: best-effort disk cleanup; the in-memory library is authoritative
	}

	func deleteVersion(_ versionId: UUID, from tweakId: UUID) {
		guard let index = tweaks.firstIndex(where: { $0.id == tweakId }) else { return }
		if let version = tweaks[index].versions.first(where: { $0.id == versionId }) {
			try? _fm.removeFileIfNeeded( // try? ok: best-effort disk cleanup; the in-memory library is authoritative
				at: _fm.tweaksLibrary(tweakId.uuidString).appendingPathComponent(version.id.uuidString)
			)
		}
		tweaks[index].versions.removeAll { $0.id == versionId }
		if tweaks[index].selectedVersionId == versionId {
			tweaks[index].selectedVersionId = tweaks[index].versions.last?.id
		}
		_save()
	}

	func setSelectedVersion(_ versionId: UUID, for tweakId: UUID) {
		guard let index = tweaks.firstIndex(where: { $0.id == tweakId }) else { return }
		tweaks[index].selectedVersionId = versionId
		_save()
	}

	/// Replaces a tweak's metadata; versions are managed separately.
	func update(_ tweak: ManagedTweak) {
		guard let index = tweaks.firstIndex(where: { $0.id == tweak.id }) else { return }
		tweaks[index] = tweak
		_save()
	}

	func mutate(_ id: UUID, _ change: (inout ManagedTweak) -> Void) {
		guard let index = tweaks.firstIndex(where: { $0.id == id }) else { return }
		change(&tweaks[index])
		_save()
	}

	func tweak(_ id: UUID) -> ManagedTweak? {
		tweaks.first { $0.id == id }
	}

	// MARK: Queries

	var injectableTweaks: [ManagedTweak] {
		tweaks.filter { $0.isEnabled && $0.activeVersion != nil }
	}

	/// Tweaks that should auto-inject when signing the given bundle id.
	func resolveAutoInject(forBundleId bundleId: String?) -> [ManagedTweak] {
		injectableTweaks.filter { $0.autoInjects(into: bundleId) }
	}

	/// Tweaks set to inject into every sign (drives the tab badge).
	var defaultInjectCount: Int {
		injectableTweaks.filter { $0.injectByDefault }.count
	}

	/// Sign-time spec from a tweak's active version: one file per component with its
	/// effective config (component override else tweak default); "selected" targeting
	/// is constrained to the app's real extensions.
	func injectionSpec(for tweak: ManagedTweak, availableAppex: [String]) -> TweakInjectionSpec? {
		guard tweak.isEnabled, let version = tweak.activeVersion else { return nil }
		let files: [TweakInjectionFile] = version.components.map { component in
			var config = component.config ?? tweak.config
			if case .selected(let names) = config.targeting {
				config.targeting = .selected(names.filter { availableAppex.contains($0) })
			}
			return TweakInjectionFile(
				fileURL: fileURL(forTweak: tweak.id, version: version, component: component),
				fileName: component.fileName,
				fileType: component.fileType,
				enabled: component.isEnabled,
				config: config
			)
		}
		guard !files.isEmpty else { return nil }
		return TweakInjectionSpec(id: tweak.id, displayName: tweak.name, isManaged: true, files: files)
	}

	// MARK: Internal

	/// Copies source files into a version directory, returning components. File names
	/// are kept (importers derive the name from them); collisions are de-duped (`Name 2.dylib`).
	private func _storeComponents(
		_ sources: [URL],
		forTweak tweakId: UUID,
		versionId: UUID,
		existing: [TweakComponent]
	) -> [TweakComponent] {
		let destDir = _fm.tweaksLibrary(tweakId.uuidString).appendingPathComponent(versionId.uuidString)
		do {
			try _fm.createDirectoryIfNeeded(at: destDir)
		} catch {
			Logger.misc.error("TweakManager store failed to create dir: \(error.localizedDescription)")
			return []
		}

		var taken = Set(existing.map { $0.fileName.lowercased() })
		var result: [TweakComponent] = []

		for source in sources {
			let needsScope = source.startAccessingSecurityScopedResource()
			defer { if needsScope { source.stopAccessingSecurityScopedResource() } }

			let fileName = _uniqueFileName(source.lastPathComponent, taken: taken)
			let dest = destDir.appendingPathComponent(fileName)
			let existed = _fm.fileExists(atPath: dest.path)
			do {
				try TweakImportSupport.validate(source)
				try _fm.copyItem(at: source, to: dest)
				try TweakImportSupport.validate(dest)
			} catch {
				if !existed { _removeRepositoryDownload(dest) }
				FileLogger.error("Tweak import failed for \(fileName): \(error.localizedDescription)", category: "tweaks")
				Logger.misc.error("TweakManager store failed for \(fileName): \(error.localizedDescription)")
				continue
			}
			taken.insert(fileName.lowercased())
			result.append(TweakComponent(
				fileName: fileName,
				fileType: TweakFileType(fileExtension: source.pathExtension),
				// Handles files and directory bundles (.framework/.bundle/.appex).
				fileSize: TweakExtractor.directorySize(at: dest)
			))
		}

		if result.isEmpty, existing.isEmpty {
			try? _fm.removeFileIfNeeded(at: destDir) // try? ok: best-effort removal of an empty import directory
		}
		return result
	}

	/// Appends " 2", " 3"… before the extension on collision (keeps the suffix intact).
	private func _uniqueFileName(_ desired: String, taken: Set<String>) -> String {
		guard taken.contains(desired.lowercased()) else { return desired }
		let url = URL(fileURLWithPath: desired)
		let ext = url.pathExtension
		let base = url.deletingPathExtension().lastPathComponent
		var n = 2
		while true {
			let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
			if !taken.contains(candidate.lowercased()) { return candidate }
			n += 1
		}
	}

	// MARK: - Export

	/// Shareable URL. A single plain file is shared via temp copy; a directory bundle
	/// or multi-file version is zipped (can't share a folder). Nil if no files.
	func exportableURL(for tweak: ManagedTweak, version: TweakVersion) -> URL? {
		let sources = fileURLs(forTweak: tweak.id, version: version)
			.filter { _fm.fileExists(atPath: $0.path) }
		guard !sources.isEmpty else { return nil }

		// Export from a temp copy so library files are never moved/altered.
		let exportDir = _fm.uniqueTemporaryDirectory("TweakExport")
		do {
			try _fm.createDirectoryIfNeeded(at: exportDir)

			if sources.count == 1 {
				let source = sources[0]
				let isDir = (try? source.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false // try? ok: best-effort directory probe; treat unreadable as a file
				if !isDir {
					let dest = exportDir.appendingPathComponent(source.lastPathComponent)
					try _fm.copyItem(at: source, to: dest)
					return dest
				}
			}

			// Directory bundle or multiple files → one zip named after the tweak.
			let safeName = tweak.name.replacingOccurrences(of: "/", with: "_")
			let zipURL = exportDir.appendingPathComponent("\(safeName.isEmpty ? "Tweak" : safeName).zip")
			try ArchiveEngine.zipItems(sources, to: zipURL)
			return zipURL
		} catch {
			Logger.misc.error("TweakManager export failed: \(error.localizedDescription)")
			return nil
		}
	}

	/// Shareable URLs for a set of tweaks (each active version).
	func exportableURLs(forTweakIds ids: Set<UUID>) -> [URL] {
		tweaks
			.filter { ids.contains($0.id) }
			.compactMap { tweak in
				guard let version = tweak.activeVersion else { return nil }
				return exportableURL(for: tweak, version: version)
			}
	}

	/// Zips a folder's active-version files into one archive.
	func exportFolder(_ folderId: UUID) -> URL? {
		let items = tweaks(inFolder: folderId).flatMap { tweak -> [URL] in
			guard let version = tweak.activeVersion else { return [] }
			return fileURLs(forTweak: tweak.id, version: version).filter { _fm.fileExists(atPath: $0.path) }
		}
		guard !items.isEmpty else { return nil }

		let name = folder(folderId)?.name ?? "Tweaks"
		let safeName = name.replacingOccurrences(of: "/", with: "_")
		let exportDir = _fm.uniqueTemporaryDirectory("TweakFolderExport")
		let zipURL = exportDir.appendingPathComponent("\(safeName).zip")
		do {
			try _fm.createDirectoryIfNeeded(at: exportDir)
			try ArchiveEngine.zipItems(items, to: zipURL)
			return zipURL
		} catch {
			Logger.misc.error("TweakManager folder export failed: \(error.localizedDescription)")
			return nil
		}
	}
}

// MARK: - Lenient array decoding

private struct _FailableElement<T: Decodable>: Decodable {
	let value: T?
	init(from decoder: Decoder) throws {
		value = try? T(from: decoder) // try? ok: lenient per-element decode; failures are dropped by decodeLenientArray
	}
}

extension TweakManager {
	/// Keep the first occurrence of each identity when merging untrusted or legacy backup arrays.
	/// The existing library is also authoritative, so incoming collisions are ignored.
	static func uniqueBackupItems<Item: Identifiable>(
		_ incoming: [Item],
		excluding existingIDs: Set<Item.ID>
	) -> [Item] where Item.ID: Hashable {
		var seen = existingIDs
		return incoming.filter { seen.insert($0.id).inserted }
	}

	/// Drops only the entries that fail to decode instead of losing the whole file.
	static func decodeLenientArray<T: Decodable>(_ type: T.Type, from data: Data) -> [T] {
		if let all = try? JSONDecoder().decode([T].self, from: data) { return all } // try? ok: lenient array decode; falls back to per-element decoding
		guard let elements = try? JSONDecoder().decode([_FailableElement<T>].self, from: data) else { return [] } // try? ok: lenient array decode; an unreadable file yields an empty array
		return elements.compactMap { $0.value }
	}
}

/// A restore commits folders first and the tweak library second. Never publishes an
/// in-memory change before its atomic manifest write, and never adopts an orphan.
enum TweakBackupMerge {
    struct Conflict: LocalizedError {
        let path: String
        var errorDescription: String? { "Tweak restore could not safely copy \(path)." }
    }

    private static func decode<T: Decodable>(_ type: T.Type, data: Data) throws -> [T] {
        guard try JSONSerialization.jsonObject(with: data) is [Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return TweakManager.decodeLenientArray(type, from: data)
    }

    static func run(
        source: URL, destination: URL, currentTweaks: [ManagedTweak], currentFolders: [TweakFolder],
        write: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) },
        onFoldersCommitted: ([TweakFolder]) -> Void, onTweaksCommitted: ([ManagedTweak]) -> Void
    ) throws -> Int {
        let fm = FileManager.default
        let foldersSource = source.appendingPathComponent("folders.json")
        let librarySource = source.appendingPathComponent("library.json")
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        if fm.fileExists(atPath: foldersSource.path) {
            let data = try Data(contentsOf: foldersSource)
            let incoming = try decode(TweakFolder.self, data: data)
            let additions = TweakManager.uniqueBackupItems(incoming, excluding: Set(currentFolders.map(\.id)))
            if !additions.isEmpty {
                let merged = currentFolders + additions
                try write(JSONEncoder().encode(merged), destination.appendingPathComponent("folders.json"))
                onFoldersCommitted(merged)
            }
        }
        guard fm.fileExists(atPath: librarySource.path) else { return 0 }
        let data = try Data(contentsOf: librarySource)
        let incoming = try decode(ManagedTweak.self, data: data)
        let additions = TweakManager.uniqueBackupItems(incoming, excluding: Set(currentTweaks.map(\.id)))
        guard !additions.isEmpty else { return 0 }
        var copied: [URL] = []
        var staging: URL?
        do {
            for tweak in additions {
                let src = source.appendingPathComponent(tweak.id.uuidString)
                let dst = destination.appendingPathComponent(tweak.id.uuidString)
                guard fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dst.path) else {
                    throw Conflict(path: tweak.id.uuidString)
                }
                let temp = destination.appendingPathComponent(".restore-\(UUID().uuidString)")
                staging = temp
                try fm.copyItem(at: src, to: temp)
                try fm.moveItem(at: temp, to: dst)
                staging = nil
                copied.append(dst)
            }
            let merged = currentTweaks + additions
            try write(JSONEncoder().encode(merged), destination.appendingPathComponent("library.json"))
            onTweaksCommitted(merged)
            return additions.count
        } catch {
            for url in copied + (staging.map { [$0] } ?? []) where fm.fileExists(atPath: url.path) {
                do { try fm.removeItem(at: url) }
                catch { Logger.misc.error("Tweak restore rollback failed for \(url.lastPathComponent): \(error.localizedDescription)") }
            }
            throw error
        }
    }
}
