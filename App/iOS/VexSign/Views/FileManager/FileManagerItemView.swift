//
//  FileManagerItemView.swift
//  VexSign
//
//  One file from Documents: preview it, edit it, rename, duplicate, move, share or delete it.
//  Property lists get the same structured and raw editors the IPA Explorer uses, plain text
//  gets the same editor, and an IPA can be handed straight to the IPA Explorer.
//

import SwiftUI
import NimbleViews
import NimbleExtensions

// MARK: - View
struct FileManagerItemView: View {
	@Environment(\.dismiss) private var dismiss

	let entry: IPAFileEntry

	@State private var _kind: IPAFileKind
	@State private var _text: String?
	@State private var _plist: [String: Any]?
	@State private var _image: UIImage?
	@State private var _hex = ""
	@State private var _attributes: [FileAttributeKey: Any] = [:]
	@State private var _didLoad = false

	@State private var _isRenaming = false
	@State private var _renameText = ""
	@State private var _isMoving = false
	@State private var _isOpeningExplorer = false
	@State private var _explorer: IPAWorkspace?

	init(entry: IPAFileEntry) {
		self.entry = entry
		__kind = State(initialValue: entry.kind)
	}

	// MARK: Body
	var body: some View {
		NBList(entry.name, displayMode: .inline, type: .list) {
			_content
			_editActions
			_fileActions
			_info
		}
		.toolbar { _toolbar }
		.alert(.localized("Rename"), isPresented: $_isRenaming) {
			TextField(.localized("New name"), text: $_renameText)
				.textInputAutocapitalization(.never)
				.autocorrectionDisabled()
			Button(.localized("Cancel"), role: .cancel) {}
			Button(.localized("Rename")) { _rename() }
		}
		.sheet(item: $_explorer) { workspace in
			IPAExplorerView(workspace: workspace)
		}
		.sheet(isPresented: $_isMoving) {
			FileManagerMoveView(item: entry.url) { _ in
				// Leave the screen once the picker is really gone, so the pops don't collide.
				Presentation.afterDismiss { dismiss() }
			}
		}
		.overlay { _busy }
		.onAppear { _load() }
	}

	// MARK: Content

	@ViewBuilder
	private var _content: some View {
		switch _kind {
		case .plist: _plistContent
		case .text: _textContent
		case .image, .pdf: _imageContent
		case .directory: _directoryContent
		case .executable, .binary, .database, .archive: _binaryContent
		}
	}

	@ViewBuilder
	private var _plistContent: some View {
		Section {
			if _plist != nil {
				NavigationLink {
					PlistNodeView(title: entry.name, value: _plist ?? [:]) { _save(plist: $0) }
				} label: {
					Label(.localized("Edit Keys"), systemImage: "list.bullet.rectangle")
				}

				NavigationLink {
					PlistRawEditorView(dict: _plist ?? [:]) { _save(plist: $0) }
				} label: {
					Label(.localized("Edit Raw Plist"), systemImage: "curlybraces")
				}
			}

			NavigationLink {
				IPAFileTextEditorView(title: entry.name, text: _text ?? "") { _save(text: $0) }
			} label: {
				Label(.localized("Edit as Text"), systemImage: "doc.text")
			}
		} header: {
			Text(.localized("Property List"))
		} footer: {
			Text(.localized("Saving writes straight to disk. An invalid property list is rejected rather than written."))
		}

		_preview(limit: 40_000)
	}

	@ViewBuilder
	private var _textContent: some View {
		Section {
			NavigationLink {
				IPAFileTextEditorView(title: entry.name, text: _text ?? "") { _save(text: $0) }
			} label: {
				Label(.localized("Edit File"), systemImage: "square.and.pencil")
			}
		}

		_preview(limit: 40_000)
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
	private var _directoryContent: some View {
		if FileManagerActions.isInsideLibraryFolder(entry.url) {
			Section {
				Text(.localized("This folder belongs to an app in the Library. Editing it here changes the app bundle that was installed."))
					.font(.footnote)
					.foregroundColor(.secondary)
			}
		}
	}

	@ViewBuilder
	private var _binaryContent: some View {
		Section {
			Text(_hex)
				.font(.system(size: 11, design: .monospaced))
				.lineLimit(80)
				.textSelection(.enabled)
		} header: {
			Text(.localized("Preview"))
		} footer: {
			Text(.localized("First bytes of the file. Binary content cannot be edited here, but it can be shared, moved or replaced by importing another file with the same name."))
		}
	}

	@ViewBuilder
	private func _preview(limit: Int) -> some View {
		Section {
			if let text = _text, !text.isEmpty {
				Text(String(text.prefix(limit)))
					.font(.system(size: 12, design: .monospaced))
					.textSelection(.enabled)
					.lineLimit(400)

				if text.count > limit {
					Text(verbatim: .localized("Preview truncated at %lld characters.", arguments: limit))
						.font(.caption2)
						.foregroundColor(.disabled())
				}
			} else {
				Text(.localized("This file is empty."))
					.font(.footnote)
					.foregroundColor(.disabled())
			}
		} header: {
			Text(.localized("Contents"))
		}
	}

	// MARK: Actions

	@ViewBuilder
	private var _editActions: some View {
		Section {
			Button {
				_renameText = entry.name
				_isRenaming = true
			} label: {
				Label(.localized("Rename"), systemImage: "pencil")
			}

			Button {
				_isMoving = true
			} label: {
				Label(.localized("Move"), systemImage: "folder")
			}

			if _isIPA {
				Button {
					_openInExplorer()
				} label: {
					Label(.localized("Open in IPA Explorer"), systemImage: "doc.text.magnifyingglass")
				}
			}

			if FileManagerActions.isTweakArchive(entry.url) {
				Button {
					FileManagerActions.sendToTweakManager(entry.url)
				} label: {
					Label(.localized("Send to Tweak Manager"), systemImage: "wrench.and.screwdriver")
				}
			}
		}
	}

	@ViewBuilder
	private var _fileActions: some View {
		Section {
			Button {
				FileManagerActions.share(entry.url)
			} label: {
				Label(.localized("Share"), systemImage: "square.and.arrow.up")
			}

			Button {
				FileManagerActions.duplicate(entry.url)
				dismiss()
			} label: {
				Label(.localized("Duplicate"), systemImage: "plus.square.on.square")
			}

			Button {
				FileManagerActions.export([entry.url])
			} label: {
				Label(.localized("Export to Files"), systemImage: "square.and.arrow.down")
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

	@ViewBuilder
	private var _busy: some View {
		if _isOpeningExplorer {
			ZStack {
				Color.black.opacity(0.25).ignoresSafeArea()
				ProgressView(.localized("Unpacking…"))
					.padding(18)
					.background(.regularMaterial, in: RoundedRectangle(cornerRadius: NBRadius.card, style: .continuous))
			}
		}
	}

	@ToolbarContentBuilder
	private var _toolbar: some ToolbarContent {
		ToolbarItem(placement: .topBarTrailing) {
			Menu {
				Button(.localized("Share"), systemImage: "square.and.arrow.up") {
					FileManagerActions.share(entry.url)
				}
				Button(.localized("Copy Path"), systemImage: "doc.on.doc") {
					FileManagerActions.copyPath(entry.url)
				}
				Button(.localized("Reload"), systemImage: "arrow.clockwise") {
					_load(force: true)
				}
			} label: {
				Image(systemName: "ellipsis.circle")
			}
		}
	}

	// MARK: Derived

	private var _isIPA: Bool {
		["ipa", "tipa"].contains(entry.url.pathExtension.lowercased())
	}

	private var _relativePath: String {
		let root = URL.documentsDirectory.standardizedFileURL.path
		let path = entry.url.standardizedFileURL.path
		guard path.hasPrefix(root) else { return entry.name }
		return String(path.dropFirst(root.count).drop { $0 == "/" })
	}
}

// MARK: - Actions
extension FileManagerItemView {
	private func _load(force: Bool = false) {
		guard !_didLoad || force else { return }
		_didLoad = true

		// The kind can change after an edit (a plist saved as XML, a replaced file).
		_kind = IPAFileLoader.kind(of: entry.url, isDirectory: entry.isDirectory)
		_attributes = (try? FileManager.default.attributesOfItem(atPath: entry.url.path)) ?? [:]

		_text = nil
		_plist = nil
		_image = nil
		_hex = ""

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
			_hex = Self._hexPreview(of: entry.url)
		case .directory:
			break
		}
	}

	private func _save(text: String) {
		guard let data = text.data(using: .utf8) else {
			Toast.error(.localized("That text could not be saved"))
			return
		}

		// A property list that no longer parses would break whatever reads it next.
		if _kind == .plist, (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) == nil {
			Toast.error(.localized("Invalid property list"), duration: .long)
			return
		}

		do {
			try data.write(to: entry.url, options: .atomic)
			_load(force: true)
			Toast.success(.localized("Saved"), systemImage: "checkmark.circle")
		} catch {
			Toast.error(error.localizedDescription, duration: .long)
		}
	}

	private func _save(plist: Any) {
		guard IPAFileLoader.write(plist: plist, to: entry.url) else {
			Toast.error(.localized("Invalid property list"), duration: .long)
			return
		}
		_load(force: true)
		Toast.success(.localized("Saved"), systemImage: "checkmark.circle")
	}

	private func _rename() {
		guard FileManagerActions.rename(entry.url, to: _renameText) != nil else { return }
		dismiss()
	}

	private func _confirmDelete() {
		var message = entry.size.formattedFileSize
		if let warning = FileManagerActions.deletionWarning(for: [entry.url]) {
			message += "\n\n" + warning
		}

		DestructiveConfirm.present(
			title: .localized("Delete %@?", arguments: entry.name),
			message: message
		) {
			FileManagerActions.delete([entry.url])
			dismiss()
		}
	}

	/// An IPA has to be unpacked into a workspace before the explorer can show it.
	private func _openInExplorer() {
		guard !_isOpeningExplorer else { return }
		_isOpeningExplorer = true

		Task { @MainActor in
			do {
				_explorer = try await IPAWorkspace.open(ipa: entry.url)
			} catch {
				// Reported with a UIKit alert: the rename alert already owns this screen's
				// SwiftUI alert slot.
				UIAlertController.showAlertWithOk(
					title: .localized("Couldn't Open That IPA"),
					message: error.localizedDescription,
					isCancel: true
				)
			}
			_isOpeningExplorer = false
		}
	}

	/// Classic hex/ASCII dump, capped so a large binary stays instant.
	private static func _hexPreview(of url: URL, bytes: Int = 1024) -> String {
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
}
