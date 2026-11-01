//
//  FileManagerView.swift
//  VexSign
//
//  A browser for VexSign's own Documents folder: every file the app stores, including the
//  parts the Library and Storage screens never show (logs, Web Manager uploads, imported
//  folders, certificates). Directories push another level, files open in
//  `FileManagerItemView` where they can be read and edited.
//
//  Files, kinds and sniffing come from `IPAFileLoader`/`IPAFileKind` — the same engine the IPA
//  Explorer uses, so a `.plist` opens with the same editor in both places.
//

import SwiftUI
import QuickLook
import NimbleViews
import NimbleExtensions

// MARK: - View
struct FileManagerView: View {
	let directory: URL
	/// The Documents root gets a title, a summary header and the "open in Files" shortcut.
	var isRoot: Bool = false

	@ObservedObject private var _storage = StorageManager.shared

	@State private var _entries: [IPAFileEntry] = []
	@State private var _sort: ItemSortOption = .nameAZ
	@State private var _showsHidden = false
	@State private var _query = ""
	@State private var _prompt: Prompt?
	@State private var _promptText = ""
	@State private var _previewURL: URL?
	@State private var _verifyURL: URL?
	@State private var _showsVerifyAlert = false
	@State private var _verifyText = ""
	@State private var _isIPSWPresenting = false

	/// The three things the "+" menu can create or bring in.
	enum Prompt: Identifiable {
		case folder
		case file
		case rename(URL)

		var id: String {
			switch self {
			case .folder: "folder"
			case .file: "file"
			case .rename(let url): "rename-\(url.path)"
			}
		}

		var title: String {
			switch self {
			case .folder: .localized("New Folder")
			case .file: .localized("New File")
			case .rename: .localized("Rename")
			}
		}

		var placeholder: String {
			switch self {
			case .folder: .localized("Folder name")
			case .file: .localized("File name")
			case .rename: .localized("New name")
			}
		}

		var confirmTitle: String {
			switch self {
			case .folder: .localized("Create")
			case .file: .localized("Create")
			case .rename: .localized("Rename")
			}
		}
	}

	// MARK: Body
	var body: some View {
		NBList(_title, displayMode: isRoot ? .large : .inline, type: .list) {
			if isRoot { _summary }

			if _visible.isEmpty {
				_emptyState
			} else {
				Section {
					ForEach(_visible) { entry in
						_row(for: entry)
					}
				} footer: {
					Text(.localized("Swipe a row for share and delete, or long press for rename, duplicate and copy path."))
				}
			}
		}
		.searchable(text: $_query, placement: .navigationBarDrawer(displayMode: .automatic))
		.toolbar { _toolbar }
		.refreshable { _load() }
		.quickLookPreview($_previewURL)
		.alert(.localized("Verify Hash"), isPresented: $_showsVerifyAlert) {
			TextField(.localized("Expected SHA-256"), text: $_verifyText)
				.textInputAutocapitalization(.never)
				.autocorrectionDisabled()
			Button(.localized("Verify")) { _runVerify() }
			Button(.localized("Cancel"), role: .cancel) { _verifyText = "" }
		} message: {
			Text(.localized("Paste the SHA-256 the source published for this file. “sha256:” prefixes are ignored."))
		}
		.sheet(isPresented: $_isIPSWPresenting) {
			IPSWBrowserView()
		}
		.alert(_prompt?.title ?? "", isPresented: _isPrompting) {
			TextField(_prompt?.placeholder ?? "", text: $_promptText)
				.textInputAutocapitalization(.never)
				.autocorrectionDisabled()
			Button(.localized("Cancel"), role: .cancel) { _prompt = nil }
			Button(_prompt?.confirmTitle ?? .localized("Create")) { _commit() }
		}
		.onAppear(perform: _load)
		// An edit inside a subfolder changes the parent's listing when the user comes back.
		.nbOnChange(of: _sort) { _ in _load() }
		.nbOnChange(of: _showsHidden) { _ in _load() }
	}

	// MARK: Header

	@ViewBuilder
	private var _summary: some View {
		Section {
			LabeledContent(.localized("Items"), value: _entries.count.description)

			if let total = _storage.report?.total {
				LabeledContent(.localized("VexSign storage"), value: total.formattedFileSize)
			}

			Button {
				if let url = directory.toSharedDocumentsURL() { UIApplication.open(url) }
			} label: {
				Label(.localized("Open in Files"), systemImage: "folder")
			}
		} header: {
			Text(.localized("Documents"))
		} footer: {
			Text(.localized("Everything VexSign keeps on this device lives here. Deleting an app folder removes its Library entry as well."))
		}
	}

	// MARK: Rows

	@ViewBuilder
	private func _row(for entry: IPAFileEntry) -> some View {
		if entry.isDirectory {
			NavigationLink {
				FileManagerView(directory: entry.url)
			} label: {
				_label(for: entry)
			}
			.swipeActions(edge: .trailing, allowsFullSwipe: true) {
				Button(role: .destructive) {
					_confirmDelete(entry)
				} label: {
					Label(.localized("Delete"), systemImage: "trash")
				}
			}
			.contextMenu { _menu(for: entry) }
		} else {
			NavigationLink {
				FileManagerItemView(entry: entry)
			} label: {
				_label(for: entry)
			}
			.swipeActions(edge: .trailing, allowsFullSwipe: true) {
				Button(role: .destructive) {
					_confirmDelete(entry)
				} label: {
					Label(.localized("Delete"), systemImage: "trash")
				}
				Button {
					FileManagerActions.share(entry.url)
				} label: {
					Label(.localized("Share"), systemImage: "square.and.arrow.up")
				}
			}
			.contextMenu { _menu(for: entry) }
		}
	}

	@ViewBuilder
	private func _label(for entry: IPAFileEntry) -> some View {
		HStack(spacing: NBSpacing.row) {
			Image(systemName: entry.kind.systemImage)
				.font(.body)
				.foregroundStyle(entry.kind.tint)
				.frame(width: 26)

			VStack(alignment: .leading, spacing: 2) {
				Text(entry.name)
					.lineLimit(1)

				Text(_subtitle(for: entry))
					.font(.caption)
					.foregroundStyle(.secondary)
					.lineLimit(1)
			}
			.frame(maxWidth: .infinity, alignment: .leading)

			if FileManagerActions.isInsideLibraryFolder(entry.url) {
				Image(systemName: "checkmark.seal")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
		}
	}

	// MARK: Hash tools

	private func _copyHash(_ url: URL) {
		DispatchQueue.global(qos: .userInitiated).async {
			guard let hash = FileIntegrity.sha256(of: url) else {
				DispatchQueue.main.async { Toast.error(.localized("Could not read the file")) }
				return
			}
			DispatchQueue.main.async {
				UIPasteboard.general.string = hash
				Toast.info(.localized("SHA-256 copied"), systemImage: "number")
			}
		}
	}

	private func _runVerify() {
		guard let url = _verifyURL else { return }
		let expected = _verifyText
		_verifyText = ""
		guard !expected.trimmingCharacters(in: .whitespaces).isEmpty else { return }

		DispatchQueue.global(qos: .userInitiated).async {
			let matches = FileIntegrity.matches(url, expected: expected)
			DispatchQueue.main.async {
				if matches {
					Toast.success(.localized("Hash matches — file is intact"))
				} else {
					Toast.error(.localized("Hash does not match — file differs from the expected one"))
				}
			}
		}
	}

	@ViewBuilder
	private func _menu(for entry: IPAFileEntry) -> some View {
		Button(.localized("Rename"), systemImage: "pencil") {
			_promptText = entry.name
			_prompt = .rename(entry.url)
		}

		Button(.localized("Duplicate"), systemImage: "plus.square.on.square") {
			if FileManagerActions.duplicate(entry.url) != nil { _load() }
		}

		if !entry.isDirectory {
			Button(.localized("Preview"), systemImage: "eye") {
				_previewURL = entry.url
			}

			Button(.localized("Share"), systemImage: "square.and.arrow.up") {
				FileManagerActions.share(entry.url)
			}

			Button(.localized("Copy SHA-256"), systemImage: "number") {
				_copyHash(entry.url)
			}

			Button(.localized("Verify Hash…"), systemImage: "checkmark.seal") {
				_verifyURL = entry.url
				_verifyText = ""
				_showsVerifyAlert = true
			}
		}

		if FileManagerActions.isTweakArchive(entry.url) {
			Button(.localized("Send to Tweak Manager"), systemImage: "wrench.and.screwdriver") {
				FileManagerActions.sendToTweakManager(entry.url)
			}
		}

		Button(.localized("Copy Path"), systemImage: "doc.on.doc") {
			FileManagerActions.copyPath(entry.url)
		}

		Divider()

		Button(.localized("Delete"), systemImage: "trash", role: .destructive) {
			_confirmDelete(entry)
		}
	}

	@ViewBuilder
	private var _emptyState: some View {
		Section {
			NBContentUnavailable(
				.localized("Nothing Here"),
				systemImage: "folder",
				description: _query.isEmpty
					? .localized("This folder is empty. Create a file or import one from Files.")
					: .localized("No file in this folder matches “%@”.", arguments: _query)
			)
			.listRowBackground(Color.clear)
		}
	}

	// MARK: Toolbar

	@ToolbarContentBuilder
	private var _toolbar: some ToolbarContent {
		ToolbarItem(placement: .topBarTrailing) {
			Menu {
				Button(.localized("New Folder"), systemImage: "folder.badge.plus") {
					_promptText = ""
					_prompt = .folder
				}
				Button(.localized("New File"), systemImage: "doc.badge.plus") {
					_promptText = ""
					_prompt = .file
				}
				Button(.localized("Import from Files…"), systemImage: "square.and.arrow.down") {
					_import()
				}

				Divider()

				Button(.localized("Firmware Browser…"), systemImage: "opticaldisc") {
					_isIPSWPresenting = true
				}
			} label: {
				Image(systemName: "plus")
			}
		}

		ToolbarItem(placement: .topBarTrailing) {
			Menu {
				Picker(.localized("Sort By"), selection: $_sort) {
					ForEach(ItemSortOption.allCases) { option in
						Label(option.label, systemImage: option.systemImage).tag(option)
					}
				}
				.pickerStyle(.inline)
				.labelsHidden()

				Divider()

				Toggle(.localized("Show Hidden Files"), isOn: $_showsHidden)
			} label: {
				Image(systemName: "arrow.up.arrow.down")
			}
		}
	}

	// MARK: Derived

	private var _title: String {
		isRoot ? .localized("File Manager") : directory.lastPathComponent
	}

	private var _visible: [IPAFileEntry] {
		let filtered = _query.isEmpty
			? _entries
			: _entries.filter { $0.name.localizedCaseInsensitiveContains(_query) }

		// Folders first, always: the sort options only order within each group.
		let comparator: (IPAFileEntry, IPAFileEntry) -> Bool = _sort.comparator()
		return filtered.sorted { lhs, rhs in
			if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
			return comparator(lhs, rhs)
		}
	}

	private func _subtitle(for entry: IPAFileEntry) -> String {
		guard entry.isDirectory else {
			return "\(entry.size.formattedFileSize) · \(entry.kind.title)"
		}
		return .localized("%lld items", arguments: entry.childCount)
	}

	private var _isPrompting: Binding<Bool> {
		Binding(
			get: { _prompt != nil },
			set: { if !$0 { _prompt = nil } }
		)
	}

}

// MARK: - Actions
extension FileManagerView {
	private func _load() {
		let directory = self.directory
		let showsHidden = _showsHidden

		// Enumerating a folder with hundreds of files stays off the main thread, and folder
		// sizes are left alone — this screen shows item counts, not bytes.
		DispatchQueue.global(qos: .userInitiated).async {
			let entries = IPAFileLoader.children(
				of: directory,
				includesHidden: showsHidden,
				measuringDirectorySize: false
			)
			DispatchQueue.main.async { _entries = entries }
		}
	}

	private func _commit() {
		guard let prompt = _prompt else { return }
		let name = _promptText

		switch prompt {
		case .folder:
			if FileManagerActions.createFolder(named: name, in: directory) != nil { _load() }
		case .file:
			if FileManagerActions.createTextFile(named: name, in: directory) != nil { _load() }
		case .rename(let url):
			if FileManagerActions.rename(url, to: name) != nil { _load() }
		}

		_prompt = nil
	}

	private func _import() {
		// The picker copies what it is given, so a cancelled selection never arrives here.
		DocumentPicker.open([.item], multiple: true) { urls in
			if FileManagerActions.importFiles(urls, into: directory) > 0 { _load() }
		}
	}

	/// Deleting has two flavours of warning: a folder takes its contents with it, and anything
	/// the Library manages takes its entry with it too.
	private func _confirmDelete(_ entry: IPAFileEntry) {
		var message = entry.isDirectory
			? .localized("This folder and everything in it are deleted.")
			: entry.size.formattedFileSize

		if let warning = FileManagerActions.deletionWarning(for: [entry.url]) {
			message += "\n\n" + warning
		}

		DestructiveConfirm.present(
			title: .localized("Delete %@?", arguments: entry.name),
			message: message
		) {
			FileManagerActions.delete([entry.url])
			_load()
		}
	}
}
