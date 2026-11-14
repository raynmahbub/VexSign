//
//  IPAFileViewerView.swift
//  VexSign
//
//  Opens one file from the IPA Explorer: property lists get the structured editor, text gets a
//  real editor, images get a preview, binaries get a hex peek and their linked libraries.
//  Everything can be renamed, replaced, shared or deleted from here.
//

import SwiftUI
import NimbleViews
import NimbleExtensions

// MARK: - View
struct IPAFileViewerView: View {
	@Environment(\.dismiss) private var dismiss
	@ObservedObject private var _workspace: IPAWorkspace

	let entry: IPAFileEntry

	@State private var _kind: IPAFileKind
	@State private var _text: String?
	@State private var _plist: [String: Any]?
	@State private var _image: UIImage?
	@State private var _hex: String = ""
	@State private var _strings: String = ""
	@State private var _binaryMode = 0
	@State private var _dylibs: [String] = []
	@State private var _binary: MachOInspector.Inspection?
	@State private var _attributes: [FileAttributeKey: Any] = [:]
	@State private var _didLoad = false

	@State private var _isPrompting = false
	@State private var _promptText = ""

	init(workspace: IPAWorkspace, entry: IPAFileEntry) {
		// The property is itself named `_workspace` (house style), so assigning the
		// wrapped value here initializes the `@ObservedObject` storage.
		self._workspace = workspace
		self.entry = entry
		__kind = State(initialValue: entry.kind)
	}

	// MARK: Body
	var body: some View {
		NBList(entry.name, displayMode: .inline, type: .list) {
			_content
			_actions
			_info
			_binaryInfo
			_links
		}
		.toolbar { _toolbar }
		.alert(.localized("Rename"), isPresented: $_isPrompting) {
			TextField(.localized("New name"), text: $_promptText)
			Button(.localized("Cancel"), role: .cancel) {}
			Button(.localized("Rename")) { _rename() }
		}
		.onAppear { _load() }
	}
}

// MARK: - Content
extension IPAFileViewerView {
	@ViewBuilder
	private var _content: some View {
		switch _kind {
		case .plist:
			_plistContent
		case .text:
			_textContent
		case .image:
			_imageContent
		case .executable, .binary, .database, .archive, .pdf, .directory:
			_binaryContent
		}
	}

	@ViewBuilder
	private var _plistContent: some View {
		Section {
			if _plist != nil {
				NavigationLink {
					PlistNodeView(title: entry.name, value: _plist ?? [:]) { newValue in
						_save(plist: newValue)
					}
				} label: {
					Label(.localized("Edit Keys"), systemImage: "list.bullet.rectangle")
				}

				NavigationLink {
					PlistRawEditorView(dict: _plist ?? [:]) { newValue in
						_save(plist: newValue)
					}
				} label: {
					Label(.localized("Edit Raw Plist"), systemImage: "curlybraces")
				}

				NavigationLink {
					IPAFileTextEditorView(
						title: entry.name,
						text: _text ?? "",
						onSave: { _save(text: $0) }
					)
				} label: {
					Label(.localized("Edit as Text"), systemImage: "doc.text")
				}
			} else {
				NavigationLink {
					IPAFileTextEditorView(
						title: entry.name,
						text: _text ?? "",
						onSave: { _save(text: $0) }
					)
				} label: {
					Label(.localized("Edit as Text"), systemImage: "doc.text")
				}
			}
		} header: {
			Text(.localized("Property List"))
		} footer: {
			Text(.localized("Changes are written straight into the app bundle. Rebuild the IPA (or re-sign) for them to take effect."))
		}

		_previewSection(limit: 40_000)
	}

	@ViewBuilder
	private var _textContent: some View {
		Section {
			NavigationLink {
				IPAFileTextEditorView(
					title: entry.name,
					text: _text ?? "",
					onSave: { _save(text: $0) }
				)
			} label: {
				Label(.localized("Edit File"), systemImage: "square.and.pencil")
			}
		}

		_previewSection(limit: 40_000)
	}

	@ViewBuilder
	private var _imageContent: some View {
		Section {
			if let image = _image {
				Image(uiImage: image)
					.resizable()
					.scaledToFit()
					.frame(maxWidth: .infinity)
					.listRowInsets(EdgeInsets())
			} else {
				Text(.localized("This image could not be decoded."))
					.font(.footnote)
					.foregroundColor(.disabled())
			}
		}
	}

	@ViewBuilder
	private var _binaryContent: some View {
		Section {
			Picker(.localized("View"), selection: $_binaryMode) {
				Text(.localized("Hex")).tag(0)
				Text(.localized("Strings")).tag(1)
			}
			.pickerStyle(.segmented)

			Text(_binaryMode == 0 ? _hex : _strings)
				.font(.system(size: 11, design: .monospaced))
				.lineLimit(_binaryMode == 0 ? 80 : 240)
				.textSelection(.enabled)
		} header: {
			Text(.localized("Binary Browser"))
		} footer: {
			Text(.localized("Hex shows the first bytes; Strings extracts printable runs from a bounded preview. Binary content cannot be edited here, but it can be replaced."))
		}
	}

	@ViewBuilder
	private func _previewSection(limit: Int) -> some View {
		Section {
			if let text = _text, !text.isEmpty {
				let shown = String(text.prefix(limit))
				Text(shown)
					.font(.system(size: 12, design: .monospaced))
					.textSelection(.enabled)
					.lineLimit(400)

				if text.count > limit {
					Text(verbatim: .localized("Preview truncated at %lld characters.", arguments: limit))
						.font(.caption2)
						.foregroundColor(.disabled())
				}
			} else {
				Text(.localized("Nothing to preview."))
					.font(.footnote)
					.foregroundColor(.disabled())
			}
		} header: {
			Text(.localized("Contents"))
		}
	}
}

// MARK: - Sections
extension IPAFileViewerView {
	@ViewBuilder
	private var _actions: some View {
		Section {
			Button {
				_promptText = entry.name
				_isPrompting = true
			} label: {
				Label(.localized("Rename"), systemImage: "pencil")
			}

			Button {
				_replace()
			} label: {
				Label(.localized("Replace"), systemImage: "arrow.triangle.2.circlepath")
			}

			Button {
				IPAExplorerActions.share(entry)
			} label: {
				Label(.localized("Share"), systemImage: "square.and.arrow.up")
			}

			if ["dylib", "deb", "framework", "bundle"].contains(entry.url.pathExtension.lowercased()) {
				Button {
					IPAExplorerActions.sendToTweakManager(entry)
				} label: {
					Label(.localized("Send to Tweak Manager"), systemImage: "wrench.and.screwdriver")
				}
			}

			Button(role: .destructive) {
				_confirmDelete()
			} label: {
				Label(.localized("Delete"), systemImage: "trash")
			}
		}
	}

	@ViewBuilder
	private var _info: some View {
		Section {
			LabeledContent(.localized("Kind"), value: _kind.title)
			LabeledContent(.localized("Size"), value: entry.size.formattedFileSize)

			if let modified = _attributes[.modificationDate] as? Date {
				LabeledContent(.localized("Modified"), value: modified.formatted(date: .abbreviated, time: .shortened))
			}

			if let permissions = _attributes[.posixPermissions] as? NSNumber {
				LabeledContent(.localized("Permissions"), value: String(format: "%o", permissions.intValue))
			}

			LabeledContent(.localized("Path")) {
				Text(verbatim: _relativePath)
					.font(.caption)
					.lineLimit(1)
					.truncationMode(.middle)
			}
			.copyableText(entry.url.path)
		} header: {
			Text(.localized("File"))
		}
	}

	/// What the binary itself says, rather than what its container is called.
	///
	/// The explorer used to list linked libraries and nothing else: no architecture, no minimum
	/// system, no encryption state, no indication that a problem exists. These are facts a user
	/// needs before deciding whether an app can be signed for a device at all.
	@ViewBuilder
	private var _binaryInfo: some View {
		if let binary = _binary, !binary.isEmpty {
			Section {
				LabeledContent(.localized("Architectures"),
							   value: binary.architectures.map(\.description).joined(separator: ", "))

				if let slice = binary.deviceNativeSlices.first ?? binary.slices.first {
					if let platform = slice.platform {
						LabeledContent(.localized("Platform"), value: platform)
					}
					if let minimum = slice.minimumSystemVersion {
						LabeledContent(.localized("Minimum iOS"), value: minimum)
					}
					if let sdk = slice.sdkVersion {
						LabeledContent(.localized("SDK"), value: sdk)
					}
					LabeledContent(.localized("Code Signature"),
								   value: slice.hasCodeSignature ? String.localized("Present") : String.localized("Missing"))
					LabeledContent(.localized("Encrypted"),
								   value: slice.isEncrypted ? String.localized("Yes") : String.localized("No"))
					ForEach(slice.runtimeSearchPaths, id: \.self) { path in
						Text(path)
							.font(.system(size: 12, design: .monospaced))
							.textSelection(.enabled)
					}
				}
			} header: {
				Text(.localized("Binary"))
			}

			if !binary.issues.isEmpty {
				Section {
					ForEach(Array(binary.issues.enumerated()), id: \.offset) { _, issue in
						Text(issue.message)
							.font(.footnote)
							.foregroundStyle(.secondary)
					}
				} header: {
					Text(.localized("Diagnostics"))
				}
			}
		}
	}

	@ViewBuilder
	private var _links: some View {
		if !_dylibs.isEmpty {
			Section {
				ForEach(_dylibs, id: \.self) { dylib in
					Text(dylib)
						.font(.system(size: 12, design: .monospaced))
						.textSelection(.enabled)
				}
			} header: {
				Text(verbatim: .localized("Linked Libraries (%lld)", arguments: _dylibs.count))
			}
		}
	}

	@ToolbarContentBuilder
	private var _toolbar: some ToolbarContent {
		ToolbarItem(placement: .topBarTrailing) {
			Menu {
				Button(.localized("Share"), systemImage: "square.and.arrow.up") {
					IPAExplorerActions.share(entry)
				}
				Button(.localized("Copy Path"), systemImage: "doc.on.doc") {
					IPAExplorerActions.copyPath(entry)
				}
				Button(.localized("Reload"), systemImage: "arrow.clockwise") {
					_load(force: true)
				}
			} label: {
				Image(systemName: "ellipsis.circle")
			}
		}
	}
}

// MARK: - Actions
@MainActor
extension IPAFileViewerView {
	private var _relativePath: String {
		let root = _workspace.appURL.standardizedFileURL.path
		let path = entry.url.standardizedFileURL.path
		guard path.hasPrefix(root) else { return entry.url.lastPathComponent }
		return String(path.dropFirst(root.count).drop { $0 == "/" })
	}

	private func _load(force: Bool = false) {
		guard !_didLoad || force else { return }
		_didLoad = true

		// The kind can change after an edit (a plist saved as XML, a replaced file).
		_kind = IPAFileLoader.kind(of: entry.url, isDirectory: entry.isDirectory)
		_attributes = (try? FileManager.default.attributesOfItem(atPath: entry.url.path)) ?? [:]

		// Only text-shaped files are read into memory: the executable alone can be hundreds of
		// megabytes, and it is shown as a hex peek instead.
		_text = nil
		_plist = nil
		_image = nil
		_hex = ""
		_strings = ""
		_binaryMode = 0
		_dylibs = []
		_binary = nil

		switch _kind {
		case .plist:
			// XML even when the file on disk is binary, so "Edit as Text" stays readable.
			_text = IPAFileLoader.plistText(at: entry.url)
			_plist = IPAFileLoader.plist(at: entry.url) as? [String: Any]
		case .text:
			_text = IPAFileLoader.text(at: entry.url)
		case .image, .pdf:
			if let data = try? Data(contentsOf: entry.url) { _image = UIImage(data: data) }
		case .executable, .binary, .database, .archive:
			_hex = Self.hexPreview(of: entry.url)
			_strings = Self.stringPreview(of: entry.url)
			if _kind == .executable {
				// One parse answers both questions: the libraries the signing sheet lists and the
				// shape this screen reports.
				let inspection = MachOInspector.inspect(fileAt: entry.url)
				_binary = inspection
				_dylibs = inspection.resolvedLinkedLibraries
			}
		case .directory:
			break
		}
	}

	/// Edits land in the app bundle right away — this is a working copy either way.
	private func _save(text: String) {
		guard let data = text.data(using: .utf8) else {
			Toast.error(.localized("That text could not be saved"))
			return
		}

		// A property list that no longer parses would break the app the moment it launches.
		if _kind == .plist, (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) == nil {
			Toast.error(.localized("Invalid property list"), duration: .long)
			return
		}

		do {
			try IPAExplorerActions.save(data: data, to: entry.url, workspace: _workspace)
			_load(force: true)
			Toast.success(.localized("Saved"), systemImage: "checkmark.circle")
		} catch {
			Toast.error(error.localizedDescription, duration: .long)
		}
	}

	private func _save(plist: Any) {
		let data: Data
		do {
			data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
		} catch {
			Toast.error(.localized("Invalid property list"), duration: .long)
			return
		}
		do {
			try IPAExplorerActions.save(data: data, to: entry.url, workspace: _workspace)
			_load(force: true)
			Toast.success(.localized("Saved"), systemImage: "checkmark.circle")
		} catch {
			Toast.error(error.localizedDescription, duration: .long)
		}
	}

	private func _rename() {
		guard IPAExplorerActions.rename(entry, to: _promptText, workspace: _workspace) != nil else { return }
		dismiss()
	}

	private func _replace() {
		DocumentPicker.open([.item]) { urls in
			guard let url = urls.first else { return }
			guard IPAExplorerActions.replace(entry, with: url, workspace: _workspace) else { return }
			_load(force: true)
		}
	}

	private func _confirmDelete() {
		DestructiveConfirm.present(
			title: .localized("Delete %@?", arguments: entry.name),
			message: entry.size.formattedFileSize
		) {
			IPAExplorerActions.delete(entry, workspace: _workspace)
			dismiss()
		}
	}

	/// Classic hex/ASCII dump, capped so a 200 MB binary stays instant.
	private static func hexPreview(of url: URL, bytes: Int = 1024) -> String {
		guard let data = IPAFileLoader.head(of: url, count: bytes), !data.isEmpty else {
			return .localized("Unreadable")
		}

		let all = [UInt8](data)
		var lines: [String] = []

		for offset in stride(from: 0, to: all.count, by: 16) {
			let chunk = Array(all[offset..<min(offset + 16, all.count)])
			let hex = chunk.map { String(format: "%02X", $0) }.joined(separator: " ")
			let ascii = chunk.map { $0 >= 32 && $0 < 127 ? Character(UnicodeScalar($0)) : "." }
			lines.append(String(format: "%08X  ", offset) + hex.padding(toLength: 47, withPad: " ", startingAt: 0) + "  " + String(ascii))
		}

		return lines.joined(separator: "\n")
	}

	/// Extracts printable UTF-8/ASCII runs without loading a potentially huge executable.
	private static func stringPreview(of url: URL, bytes: Int = 64 * 1024) -> String {
		guard let data = IPAFileLoader.head(of: url, count: bytes), !data.isEmpty else {
			return .localized("Unreadable")
		}
		var result: [String] = []
		var current: [UInt8] = []
		for byte in data {
			if byte >= 32 && byte < 127 {
				current.append(byte)
			} else if current.count >= 4 {
				result.append(String(decoding: current, as: UTF8.self))
				current.removeAll(keepingCapacity: true)
			} else {
				current.removeAll(keepingCapacity: true)
			}
		}
		if current.count >= 4 { result.append(String(decoding: current, as: UTF8.self)) }
		return result.isEmpty ? .localized("No printable strings found in the preview.") : result.joined(separator: "\n")
	}
}

// MARK: - Text editor
/// Minimal full-screen editor for one file, used for text files and plists that are not
/// dictionary-rooted. Nothing is written until the text is valid.
struct IPAFileTextEditorView: View {
	@Environment(\.dismiss) private var dismiss

	let title: String
	let onSave: (String) -> Void

	@State private var _text: String
	private let _initialText: String

	init(title: String, text: String, onSave: @escaping (String) -> Void) {
		self.title = title
		self.onSave = onSave
		self._initialText = text
		__text = State(initialValue: text)
	}

	var body: some View {
		TextEditor(text: $_text)
			.font(.system(.footnote, design: .monospaced))
			.autocorrectionDisabled()
			.textInputAutocapitalization(.never)
			.padding(.horizontal, 8)
			.navigationTitle(title)
			.navigationBarTitleDisplayMode(.inline)
			.dismissableKeyboard()
			.toolbar {
				NBToolbarButton(
					.localized("Save"),
					style: .text,
					placement: .confirmationAction,
					isDisabled: _text == _initialText
				) {
					onSave(_text)
					dismiss()
				}
			}
	}
}
