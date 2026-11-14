//
//  FileManagerMoveView.swift
//  VexSign
//
//  Destination picker for "Move" in the File Manager. Documents only — moving a file into a
//  `Signed/<uuid>` or `Unsigned/<uuid>` folder would splice it into an app bundle the Library
//  points at, so those levels are shown but refused.
//

import SwiftUI
import NimbleViews
import NimbleExtensions

// MARK: - View
struct FileManagerMoveView: View {
	@Environment(\.dismiss) private var dismiss

	/// What is being moved. Its own folder, and everything inside it, are not options.
	let item: URL
	/// The folder currently being browsed. Nested levels push another one of these.
	let directory: URL
	let onMove: (URL) -> Void

	@State private var _folders: [IPAFileEntry] = []

	init(item: URL, directory: URL? = nil, onMove: @escaping (URL) -> Void) {
		self.item = item
		self.directory = directory ?? item.deletingLastPathComponent()
		self.onMove = onMove
	}

	// MARK: Body
	var body: some View {
		NBNavigationView(.localized("Move"), displayMode: .inline) {
			List {
				Section {
					Button {
						_move(to: directory)
					} label: {
						Label(.localized("Move Here"), systemImage: "arrow.down.doc")
					}
					.disabled(!_canMove(into: directory))
				} footer: {
					Text(verbatim: _path(directory))
				}

				if !_folders.isEmpty {
					Section {
						ForEach(_folders) { folder in
							if _canMove(into: folder.url) {
								NavigationLink {
									FileManagerMoveView(item: item, directory: folder.url, onMove: onMove)
								} label: {
									Label(folder.name, systemImage: "folder")
								}
							} else {
								Label(folder.name, systemImage: "folder")
									.foregroundStyle(.secondary)
							}
						}
					} header: {
						Text(.localized("Subfolders"))
					} footer: {
						Text(.localized("Greyed out folders are the app's own managed folders, or the item's current home."))
					}
				}
			}
			.toolbar {
				NBToolbarButton(role: .cancel)
			}
		}
		.onAppear(perform: _load)
	}

	// MARK: Derived

	private func _canMove(into folder: URL) -> Bool {
		let target = folder.standardizedFileURL.path
		let itemPath = item.standardizedFileURL.path

		// Not into itself, not into its own subtree, and not into where it already is.
		guard target != itemPath, !target.hasPrefix(itemPath + "/") else { return false }
		guard target != item.deletingLastPathComponent().standardizedFileURL.path else { return false }

		return !FileManagerActions.isInsideLibraryFolder(folder)
	}

	private func _path(_ url: URL) -> String {
		let root = URL.documentsDirectory.standardizedFileURL.path
		let path = url.standardizedFileURL.path
		guard path.hasPrefix(root) else { return url.lastPathComponent }

		let relative = String(path.dropFirst(root.count).drop { $0 == "/" })
		return relative.isEmpty ? .localized("Documents") : "Documents/\(relative)"
	}

	// MARK: Actions

	private func _load() {
		let directory = self.directory

		// Only folders are listed, and their sizes are never shown, so the recursive size walk
		// is skipped here the same way the browser skips it.
		DispatchQueue.global(qos: .userInitiated).async {
			let folders = IPAFileLoader.children(
				of: directory,
				includesHidden: false,
				measuringDirectorySize: false
			)
			.filter { $0.isDirectory }
			DispatchQueue.main.async { _folders = folders }
		}
	}

	private func _move(to folder: URL) {
		guard FileManagerActions.move(item, into: folder) != nil else { return }
		onMove(folder)
		dismiss()
	}
}
