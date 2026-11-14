//
//  IPAExplorerHomeView.swift
//  VexSign
//
//  Entry point for the IPA Explorer: open an IPA from Files, pick an app already in the library,
//  or jump back into a workspace that is still on disk.
//

import SwiftUI
import NimbleViews
import NimbleExtensions

// MARK: - Library shortcut
/// Opens a library app in the explorer. `embedded` is for pushing from an existing navigation
/// stack (Library → Get Info → Browse Files); sheets use the default and bring their own stack.
struct IPALibraryExplorerView: View {
	var app: AppInfoPresentable
	var embedded: Bool = false

	@State private var _workspace: IPAWorkspace?
	@State private var _error: String?

	var body: some View {
		Group {
			if let workspace = _workspace {
				IPAExplorerView(workspace: workspace, embedded: embedded)
			} else if let error = _error {
				NBContentUnavailable(
					.localized("Couldn't Open This App"),
					systemImage: "exclamationmark.triangle",
					description: error
				)
			} else {
				ProgressView()
					.frame(maxWidth: .infinity, maxHeight: .infinity)
			}
		}
		.onAppear {
			guard _workspace == nil, _error == nil else { return }
			do {
				_workspace = try IPAWorkspace.open(app: app)
			} catch {
				_error = error.localizedDescription
			}
		}
	}
}

// MARK: - View
struct IPAExplorerHomeView: View {
	@State private var _workspace: IPAWorkspace?
	@State private var _recents: [IPAWorkspaceRecord] = []
	@State private var _isPickingApp = false
	@State private var _isOpening = false
	@State private var _error: String?

	// MARK: Body
	var body: some View {
		NBList(.localized("IPA Explorer")) {
			NBSection(.localized("Open"), systemName: "doc.badge.plus") {
				Button {
					_openFile()
				} label: {
					Label(.localized("Choose an IPA…"), systemImage: "square.and.arrow.down")
				}

				Button {
					_isPickingApp = true
				} label: {
					Label(.localized("Browse a Library App…"), systemImage: "square.grid.2x2")
				}
			} footer: {
				Text(.localized("An IPA is unpacked into a private workspace, so nothing is touched until you rebuild it or sign and install it. Library apps are edited in place."))
			}

			_recentsSection

			NBSection(.localized("What You Can Do")) {
				_helpRow("doc.text.magnifyingglass", .localized("See every file"), .localized("Browse Payload and the app bundle, including hidden files."))
				_helpRow("list.bullet.rectangle", .localized("Edit property lists"), .localized("Change bundle identifier, name, version, capabilities and any other key, or edit the raw XML."))
				_helpRow("square.and.pencil", .localized("Edit text files"), .localized("Themes, configs, .strings localizations and anything else that is plain text."))
				_helpRow("photo", .localized("Swap images and icons"), .localized("Replace icons, launch images or any asset with one from Files."))
				_helpRow("plus.square.on.square", .localized("Add, rename, delete"), .localized("Drop new dylibs, frameworks or bundles in, rename or remove what the app ships with."))
				_helpRow("archivebox", .localized("Rebuild or install"), .localized("Rebuild the edited IPA, or sign and install it straight away."))
			}
		}
		.sheet(item: $_workspace) { workspace in
			IPAExplorerView(workspace: workspace)
		}
		.sheet(isPresented: $_isPickingApp) {
			// The picker dismisses itself first; presenting the explorer while it is still on
			// screen would be dropped by SwiftUI.
			AppLibraryPicker(showsChevron: true) { app in
				Presentation.afterDismiss { _openLibraryApp(app) }
			}
		}
		.overlay { _busy }
		.alert(
			.localized("Couldn't Open That IPA"),
			isPresented: Binding(get: { _error != nil }, set: { if !$0 { _error = nil } })
		) {
			Button("OK", role: .cancel) {}
		} message: {
			Text(_error ?? "")
		}
		.onAppear(perform: _loadRecents)
		.undoableRemovalBanner()
	}
}

// MARK: - Sections
extension IPAExplorerHomeView {
	@ViewBuilder
	private var _recentsSection: some View {
		if !_recents.isEmpty {
			NBSection(.localized("Recent"), secondary: "\(_recents.count)", systemName: "clock.arrow.circlepath") {
				ForEach(_recents) { record in
					Button {
						_open(record)
					} label: {
						HStack(spacing: 12) {
							Image(systemName: "doc.zipper")
								.foregroundStyle(.tint)
								.frame(width: 26)

							VStack(alignment: .leading, spacing: 2) {
								Text(record.name)
									.foregroundStyle(.primary)
									.lineLimit(1)
									.truncationMode(.middle)
								Text(verbatim: record.date.formatted(date: .abbreviated, time: .shortened))
									.font(.caption)
									.foregroundStyle(.secondary)
							}

							Spacer(minLength: 0)

							Image(systemName: "chevron.right")
								.font(.caption.weight(.semibold))
								.foregroundStyle(.tertiary)
						}
					}
					.swipeActions(edge: .trailing, allowsFullSwipe: false) {
						Button(role: .destructive) {
							RecoverableFileRemoval.removeOfferingUndo(record.url) { _loadRecents() }
						} label: {
							Label(.localized("Delete"), systemImage: "trash")
						}
					}
				}

				Button(role: .destructive) {
					DestructiveConfirm.present(
						title: .localized("Clear Workspaces?"),
						message: .localized("Every unpacked IPA waiting here will be deleted. Apps already in your library are not touched.")
					) {
						IPAWorkspace.discardAll()
						_loadRecents()
					}
				} label: {
					Label(.localized("Clear All Workspaces"), systemImage: "trash")
				}
			} footer: {
				Text(.localized("Workspaces are kept so you can come back to an edit later. They use space, so clear them when you are done."))
			}
		}
	}

	@ViewBuilder
	private func _helpRow(_ systemImage: String, _ title: String, _ description: String) -> some View {
		Label {
			VStack(alignment: .leading, spacing: 2) {
				Text(title)
				Text(description)
					.font(.caption)
					.foregroundStyle(.secondary)
			}
		} icon: {
			Image(systemName: systemImage)
				.foregroundStyle(.tint)
		}
	}

	@ViewBuilder
	private var _busy: some View {
		if _isOpening {
			ZStack {
				Color.black.opacity(0.2).ignoresSafeArea()
				VStack(spacing: 12) {
					ProgressView()
					Text(.localized("Unpacking IPA…"))
						.font(.footnote)
				}
				.padding(22)
				.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
			}
		}
	}
}

// MARK: - Actions
@MainActor
extension IPAExplorerHomeView {
	private func _loadRecents() {
		_recents = IPAWorkspace.recents()
	}

	private func _openFile() {
		DocumentPicker.open([.item], multiple: false) { urls in
			guard let url = urls.first else { return }
			_open(url)
		}
	}

	private func _open(_ url: URL) {
		_isOpening = true
		Task {
			do {
				let workspace = try await IPAWorkspace.open(ipa: url)
				_isOpening = false
				_workspace = workspace
			} catch {
				_isOpening = false
				_error = error.localizedDescription
			}
			_loadRecents()
		}
	}

	private func _open(_ record: IPAWorkspaceRecord) {
		do {
			_workspace = try IPAWorkspace.open(recent: record)
		} catch {
			_error = error.localizedDescription
			_loadRecents()
		}
	}

	private func _openLibraryApp(_ app: AppInfoPresentable) {
		do {
			_workspace = try IPAWorkspace.open(app: app)
		} catch {
			_error = error.localizedDescription
		}
	}
}
