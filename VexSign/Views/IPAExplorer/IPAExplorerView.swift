//
//  IPAExplorerView.swift
//  VexSign
//
//  The file browser for an IPA (or a library app): every folder and file inside the bundle,
//  with editing, adding, renaming, replacing and deleting — then rebuild the IPA or sign and
//  install the result. The same view renders the root of the tree and every subfolder, which is
//  why the root is the only one that wraps itself in a navigation stack.
//

import SwiftUI
import NimbleViews
import NimbleExtensions

// MARK: - View
struct IPAExplorerView: View {
	@Environment(\.dismiss) private var dismiss
	@ObservedObject private var _workspace: IPAWorkspace

	private let _directory: URL
	private let _isRoot: Bool
	/// False when the view is pushed into a stack that already exists (Library → Get Info).
	private let _ownsStack: Bool

	@State private var _entries: [IPAFileEntry] = []
	@State private var _query = ""
	@State private var _showsHidden = false
	@State private var _showsContainer = false
	@AppStorage("VexSign.explorerSort") private var _sortRaw = ItemSortOption.nameAZ.rawValue

	@State private var _prompt: Prompt?
	@State private var _isPrompting = false
	@State private var _promptText = ""

	@State private var _summary: IPABundleSummary?
	@State private var _isWorking = false
	@State private var _didLoad = false

	// MARK: Init
	init(workspace: IPAWorkspace, embedded: Bool = false) {
		// The property is itself named `_workspace` (house style), so assigning the
		// wrapped value here initializes the `@ObservedObject` storage.
		self._workspace = workspace
		self._directory = workspace.appURL
		self._isRoot = true
		self._ownsStack = !embedded
	}

	init(workspace: IPAWorkspace, directory: URL) {
		self._workspace = workspace
		self._directory = directory
		self._isRoot = false
		self._ownsStack = false
	}

	private enum Prompt: Equatable {
		case newFolder
		case rename(IPAFileEntry)

		var title: String {
			switch self {
			case .newFolder:	.localized("New Folder")
			case .rename:		.localized("Rename")
			}
		}

		var placeholder: String {
			switch self {
			case .newFolder:	.localized("Folder name")
			case .rename:		.localized("New name")
			}
		}

		var confirmTitle: String {
			switch self {
			case .newFolder:	.localized("Create")
			case .rename:		.localized("Rename")
			}
		}
	}

	// MARK: Body
	var body: some View {
		Group {
			if _ownsStack {
				NBNavigationView(_isRoot ? _workspace.name : _directory.lastPathComponent, displayMode: .inline) { _content }
			} else {
				_content
					.navigationTitle(_isRoot ? _workspace.name : _directory.lastPathComponent)
					.navigationBarTitleDisplayMode(.inline)
			}
		}
		.onAppear(perform: _load)
		.nbOnChange(of: _workspace.changeCount) { _ in _reload() }
		.nbOnChange(of: _showsHidden) { _ in _reload() }
	}

	@ViewBuilder
	private var _content: some View {
		NBList(_title, displayMode: .inline, type: .list) {
			if _isRoot {
				_summarySection
			}

			_entriesSection
		}
		.searchable(
			text: $_query,
			placement: .navigationBarDrawer(displayMode: .automatic),
			prompt: Text(.localized("Search files"))
		)
		.overlay { _busyOverlay }
		.toolbar { _toolbar }
		.alert(_prompt?.title ?? "", isPresented: $_isPrompting, presenting: _prompt) { prompt in
			TextField(prompt.placeholder, text: $_promptText)
			Button(.localized("Cancel"), role: .cancel) {}
			Button(.localized(prompt.confirmTitle)) { _apply(prompt) }
		}
	}
}

// MARK: - Sections
extension IPAExplorerView {
	@ViewBuilder
	private var _summarySection: some View {
		NBSection(_workspace.name, secondary: _workspace.isDirty ? String.localized("Edited") : nil) {
			if let summary = _summary {
				HStack(spacing: 14) {
					_summaryIcon(summary)

					VStack(alignment: .leading, spacing: 3) {
						Text(summary.name)
							.font(.headline)
							.lineLimit(1)
						Text(summary.identifier)
							.font(.caption)
							.foregroundStyle(.secondary)
							.lineLimit(1)
							.truncationMode(.middle)
						Text(verbatim: "\(summary.version) · iOS \(summary.minimumOS ?? "—") · \(summary.fileCount) \(String.localized("files"))")
							.font(.caption2)
							.foregroundStyle(.secondary)
					}

					Spacer(minLength: 0)
				}
				.padding(.vertical, 4)

				LabeledContent(.localized("Path")) {
					Text(verbatim: _workspace.displayPath)
						.font(.caption)
						.lineLimit(1)
						.truncationMode(.middle)
				}
				.copyableText(_workspace.appURL.path)

				LabeledContent(.localized("Size")) {
					Text(verbatim: _workspace.totalSize.formattedFileSize)
						.font(.subheadline)
						.foregroundStyle(.secondary)
				}

				Toggle(.localized("Browse From IPA Root"), isOn: $_showsContainer)
			} else {
				Text(.localized("This bundle could not be read."))
					.font(.footnote)
					.foregroundColor(.disabled())
			}
		} footer: {
			Text(.localized("Everything here is edited in place. Rebuild the IPA when you are done, or sign and install this app straight away — VexSign signs a copy, so your edits stay in the workspace until you rebuild."))
		}
	}

	@ViewBuilder
	private func _summaryIcon(_ summary: IPABundleSummary) -> some View {
		Group {
			if let icon = summary.icon {
				Image(uiImage: icon)
					.resizable()
					.scaledToFit()
			} else {
				Image(systemName: "app.dashed")
					.resizable()
					.scaledToFit()
					.padding(10)
					.foregroundStyle(.secondary)
			}
		}
		.frame(width: 54, height: 54)
		.background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
	}

	@ViewBuilder
	private var _entriesSection: some View {
		Section {
			if _filtered.isEmpty {
				Text(verbatim: _query.isEmpty ? String.localized("This folder is empty") : String.localized("No Results"))
					.font(.footnote)
					.foregroundColor(.disabled())
			} else {
				ForEach(_filtered) { entry in
					_row(entry)
				}
			}
		} header: {
			if !_filtered.isEmpty {
				Text(verbatim: .localized("%lld items · %@", arguments: _filtered.count, _total.formattedFileSize))
			}
		} footer: {
			if _isRoot {
				Text(verbatim: _currentDirectory.path)
					.font(.caption2)
					.lineLimit(1)
					.truncationMode(.middle)
			}
		}
	}

	@ViewBuilder
	private func _row(_ entry: IPAFileEntry) -> some View {
		if entry.isDirectory {
			NavigationLink {
				IPAExplorerView(workspace: _workspace, directory: entry.url)
			} label: {
				IPAFileRow(entry: entry)
			}
			.swipeActions(edge: .trailing) { _actions(entry) }
			.contextMenu { _menu(entry) }
		} else {
			NavigationLink {
				IPAFileViewerView(workspace: _workspace, entry: entry)
			} label: {
				IPAFileRow(entry: entry)
			}
			.swipeActions(edge: .trailing) { _actions(entry) }
			.contextMenu { _menu(entry) }
		}
	}

	@ViewBuilder
	private var _busyOverlay: some View {
		if _isWorking || _workspace.isBusy {
			ZStack {
				Color.black.opacity(0.25).ignoresSafeArea()
				VStack(spacing: 12) {
					if _workspace.progress > 0, _workspace.progress < 1 {
						ProgressView(value: _workspace.progress)
							.progressViewStyle(.linear)
							.frame(width: 200)
					} else {
						ProgressView()
					}
					Text(.localized("Rebuilding IPA…"))
						.font(.footnote)
				}
				.padding(20)
				.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
			}
			.transition(.opacity)
		}
	}
}

// MARK: - Menus
extension IPAExplorerView {
	@ViewBuilder
	private func _actions(_ entry: IPAFileEntry) -> some View {
		Button(role: .destructive) {
			_confirmDelete(entry)
		} label: {
			Label(.localized("Delete"), systemImage: "trash")
		}
	}

	@ViewBuilder
	private func _menu(_ entry: IPAFileEntry) -> some View {
		Button(.localized("Rename"), systemImage: "pencil") {
			_present(.rename(entry), text: entry.name)
		}
		Button(.localized("Replace"), systemImage: "arrow.triangle.2.circlepath") {
			_replace(entry)
		}
		Button(.localized("Share"), systemImage: "square.and.arrow.up") {
			IPAExplorerActions.share(entry)
		}
		Button(.localized("Copy Path"), systemImage: "doc.on.doc") {
			IPAExplorerActions.copyPath(entry)
		}
		if ["dylib", "deb", "framework", "bundle"].contains(entry.url.pathExtension.lowercased()) {
			Button(.localized("Send to Tweak Manager"), systemImage: "wrench.and.screwdriver") {
				IPAExplorerActions.sendToTweakManager(entry)
			}
		}
		Divider()
		Button(.localized("Delete"), systemImage: "trash", role: .destructive) {
			_confirmDelete(entry)
		}
	}

	@ToolbarContentBuilder
	private var _toolbar: some ToolbarContent {
		if _isRoot, _ownsStack {
			ToolbarItem(placement: .topBarLeading) {
				Button(String.localized(_workspace.isDirty ? "Close" : "Done")) { _close() }
			}
		}

		ToolbarItem(placement: .topBarTrailing) {
			Menu {
				Button(.localized("New Folder"), systemImage: "folder.badge.plus") {
					_present(.newFolder, text: "")
				}
				Button(.localized("Add Files"), systemImage: "doc.badge.plus") {
					_addFiles()
				}

				Divider()

				if !_workspace.isLibraryApp {
					Button(.localized("Rebuild IPA"), systemImage: "archivebox") {
						_rebuild { _presentBuiltOptions($0) }
					}
					.disabled(_isWorking)
				}

				Button(.localized("Sign & Install"), systemImage: "square.and.arrow.down.on.square") {
					_signAndInstall()
				}
				.disabled(_isWorking)

				Divider()

				if let journal = _workspace.journal {
					NavigationLink {
						IPAChangeListView(workspace: _workspace, journal: journal)
					} label: {
						Label(.localized("Undo / Recent Changes"), systemImage: "arrow.uturn.backward")
					}
				}

				Toggle(.localized("Show Hidden Files"), isOn: $_showsHidden)

				if !_workspace.isLibraryApp {
					Button(.localized("Reveal in Files"), systemImage: "folder") {
						UIApplication.open(_workspace.containerURL.toSharedDocumentsURL() ?? _workspace.containerURL)
					}
				}
			} label: {
				Image(systemName: "ellipsis.circle")
			}
		}
	}
}

// MARK: - Actions
@MainActor
extension IPAExplorerView {
	private var _title: String {
		_isRoot ? _workspace.name : _directory.lastPathComponent
	}

	private var _currentDirectory: URL {
		(_isRoot && _showsContainer) ? _workspace.containerURL : _directory
	}

	private var _sort: ItemSortOption {
		ItemSortOption(rawValue: _sortRaw) ?? .nameAZ
	}

	private var _filtered: [IPAFileEntry] {
		let query = _query.trimmingCharacters(in: .whitespaces)
		let matched = query.isEmpty ? _entries : _entries.filter { $0.name.localizedCaseInsensitiveContains(query) }
		// Folders always stay on top, whatever the sort order.
		return matched.sorted { lhs, rhs in
			if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
			return _sort.comparator()(lhs, rhs)
		}
	}

	private var _total: Int64 {
		_filtered.reduce(0) { $0 + $1.size }
	}

	private func _load() {
		guard !_didLoad else { _reload(); return }
		_didLoad = true
		_summary = _isRoot ? IPABundleSummary.read(at: _workspace.appURL) : nil
		_reload()
	}

	private func _reload() {
		_entries = IPAFileLoader.children(of: _currentDirectory, includesHidden: _showsHidden)
	}

	private func _present(_ prompt: Prompt, text: String) {
		_promptText = text
		_prompt = prompt
		_isPrompting = true
	}

	private func _apply(_ prompt: Prompt) {
		switch prompt {
		case .newFolder:
			IPAExplorerActions.createFolder(named: _promptText, in: _currentDirectory, workspace: _workspace)
		case .rename(let entry):
			IPAExplorerActions.rename(entry, to: _promptText, workspace: _workspace)
		}
		_promptText = ""
		_prompt = nil
		_reload()
	}

	private func _addFiles() {
		DocumentPicker.open([.item], multiple: true) { urls in
			let added = IPAExplorerActions.importFiles(urls, into: _currentDirectory, workspace: _workspace)
			if added == 0 {
				Toast.error(.localized("Nothing was added — a file with that name already exists here."), duration: .long)
			}
			_load()
		}
	}

	private func _replace(_ entry: IPAFileEntry) {
		DocumentPicker.open([.item]) { urls in
			guard let url = urls.first else { return }
			IPAExplorerActions.replace(entry, with: url, workspace: _workspace)
			_reload()
		}
	}

	private func _confirmDelete(_ entry: IPAFileEntry) {
		DestructiveConfirm.present(
			title: .localized("Delete %@?", arguments: entry.name),
			message: entry.isDirectory
				? .localized("The folder and everything inside it will be removed from the app.")
				: entry.size.formattedFileSize
		) {
			IPAExplorerActions.delete(entry, workspace: _workspace)
			_reload()
		}
	}

	private func _rebuild(_ completion: @escaping (URL) -> Void) {
		_isWorking = true
		Task {
			do {
				let url = try await _workspace.rebuild()
				_isWorking = false
				_reload()
				completion(url)
			} catch {
				_isWorking = false
				Toast.error(error.localizedDescription, duration: .sticky)
			}
		}
	}

	private func _presentBuiltOptions(_ url: URL) {
		let share = UIAlertAction(title: .localized("Share IPA"), style: .default) { _ in
			UIActivityViewController.show(activityItems: [url])
		}
		let open = UIAlertAction(title: .localized("Reveal in Files"), style: .default) { _ in
			UIApplication.open(url.toSharedDocumentsURL() ?? url)
		}
		let install = UIAlertAction(title: .localized("Sign & Install"), style: .default) { _ in
			_signAndInstall()
		}

		UIAlertController.showAlertWithCancel(
			title: .localized("IPA Ready"),
			message: "\(url.lastPathComponent)\n\(FileManager.default.allocatedSize(at: url).formattedFileSize)",
			style: UIDevice.current.userInterfaceIdiom == .pad ? .alert : .actionSheet,
			actions: [install, share, open]
		)
	}

	private func _signAndInstall() {
		_isWorking = true
		Task {
			do {
				try await _workspace.signAndInstall()
				_isWorking = false
				Toast.success(.localized("Installing…"), systemImage: "square.and.arrow.down")
				if _isRoot { dismiss() }
			} catch {
				_isWorking = false
				Toast.error(error.localizedDescription, duration: .sticky)
			}
		}
	}

	private func _close() {
		guard _workspace.isDirty, !_workspace.isLibraryApp else {
			dismiss()
			return
		}

		DestructiveConfirm.present(
			title: .localized("Discard Changes?"),
			message: .localized("The IPA has not been rebuilt, so your edits are only in this workspace.")
		) {
			_workspace.discard()
			dismiss()
		}
	}
}

// MARK: - Row
struct IPAFileRow: View {
	let entry: IPAFileEntry

	var body: some View {
		HStack(spacing: 12) {
			Image(systemName: entry.kind.systemImage)
				.foregroundStyle(entry.kind.tint)
				.frame(width: 26)

			VStack(alignment: .leading, spacing: 2) {
				Text(entry.name)
					.lineLimit(1)
					.truncationMode(.middle)
				Text(verbatim: _subtitle)
					.font(.caption)
					.foregroundStyle(.secondary)
			}

			Spacer(minLength: 0)

			if entry.isDirectory {
				Text(verbatim: "\(entry.childCount)")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
		}
	}

	private var _subtitle: String {
		if entry.isDirectory {
			return entry.kind.title
		}
		return "\(entry.kind.title) · \(entry.size.formattedFileSize)"
	}
}
