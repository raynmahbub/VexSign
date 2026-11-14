//
//  SigningEntitlementsView.swift
//  VexSign
//
//  Created by VexSign Contributors on 20.04.2025.
//

import SwiftUI
import NimbleViews
import NimbleExtensions

// MARK: - View
struct SigningEntitlementsView: View {
	@ObservedObject private var _manager = EntitlementsManager.shared

	@Binding var bindingValue: URL?
	var app: AppInfoPresentable?
	var certificate: CertificatePair?

	@State private var _isRenamingPresenting = false
	@State private var _fileToRename: EntitlementsFile?
	@State private var _newName = ""
	@State private var _isDeleteConfirming = false
	@State private var _fileToDelete: EntitlementsFile?
	@State private var _isPushingNewEntry = false
	@State private var _pushedEntry: EntitlementsFile?

	// MARK: Body
	var body: some View {
		NBList(.localized("Entitlements")) {
			if _manager.files.isEmpty {
				Section {
					Text(.localized("No entitlements files yet"))
						.foregroundStyle(.secondary)
				}
			} else {
				Section {
					ForEach(_manager.files) { file in
						_row(for: file)
					}
				} footer: {
					Text(.localized("Custom entitlements are signed as-is. Entries not granted by your certificate's provisioning profile may fail to install or crash at launch."))
				}
			}
		}
		.toolbar {
			NBToolbarMenu(
				systemImage: "plus",
				style: .icon,
				placement: .topBarTrailing
			) {
				_creationActions
			}
		}
		.alert(.localized("Rename"), isPresented: $_isRenamingPresenting, presenting: _fileToRename) { file in
			TextField(.localized("Name"), text: $_newName)
			Button(.localized("Cancel"), role: .cancel) {}
			Button(.localized("OK")) {
				_manager.rename(file.id, to: _newName)
			}
		}
		.confirmationDialog(.localized("Delete custom entitlements?"), isPresented: $_isDeleteConfirming, titleVisibility: .visible) {
			Button(.localized("Delete"), role: .destructive) {
				if let file = _fileToDelete {
					if bindingValue == _manager.fileURL(for: file) { bindingValue = nil }
					_manager.delete(file.id)
				}
				_fileToDelete = nil
			}
			Button(.localized("Cancel"), role: .cancel) { _fileToDelete = nil }
		} message: {
			Text(_fileToDelete?.name ?? "")
		}
		.navigationDestination(isPresented: $_isPushingNewEntry) {
			if let _pushedEntry {
				SigningEntitlementsEditorView(entry: _pushedEntry, certificate: certificate)
			}
		}
		.onAppear(perform: _syncSelection)
		.nbOnChange(of: _manager.files) { _ in _syncSelection() }
	}
}

// MARK: - Extension: Rows
extension SigningEntitlementsView {
	@ViewBuilder
	private func _row(for file: EntitlementsFile) -> some View {
		let isSelected = bindingValue == _manager.fileURL(for: file)

		HStack {
			Button {
				bindingValue = isSelected ? nil : _manager.fileURL(for: file)
			} label: {
				Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
					.foregroundStyle(isSelected ? Color.accentColor : .secondary)
					.imageScale(.large)
			}
			.buttonStyle(.plain)

			NavigationLink {
				SigningEntitlementsEditorView(entry: file, certificate: certificate)
			} label: {
				VStack(alignment: .leading, spacing: 2) {
					Text(file.name)
					Text(file.createdAt, style: .date)
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			}
			Menu {
				Button(.localized("Rename"), systemImage: "pencil") {
					_newName = file.name
					_fileToRename = file
					_isRenamingPresenting = true
				}
				Button(.localized("Delete"), systemImage: "trash", role: .destructive) {
					_fileToDelete = file
					_isDeleteConfirming = true
				}
			} label: {
				Image(systemName: "ellipsis.circle")
					.imageScale(.large)
			}
			.accessibilityLabel(.localized("Entitlements file actions"))
		}
		.badge(PlistDiff.flaggedCount(in: _manager.load(file), against: _grantedEntitlements))
		.swipeActions(edge: .trailing, allowsFullSwipe: false) {
			Button(role: .destructive) {
				_fileToDelete = file
				_isDeleteConfirming = true
			} label: {
				Label(.localized("Delete"), systemImage: "trash")
			}
			Button {
				_newName = file.name
				_fileToRename = file
				_isRenamingPresenting = true
			} label: {
				Label(.localized("Rename"), systemImage: "pencil")
			}
			.tint(.blue)
		}
	}

	@ViewBuilder
	private var _creationActions: some View {
		Button(.localized("Import File"), systemImage: "square.and.arrow.down") {
			DocumentPicker.open([.xmlPropertyList, .plist, .entitlements, .mobileProvision, .json], folder: .entitlements) { urls in
				guard let url = urls.first else { return }
				if let entry = _manager.addImported(name: url.deletingPathExtension().lastPathComponent, from: url) {
					_select(entry, push: true)
				} else {
					Toast.error(.localized("Couldn't read entitlements from that file"))
				}
			}
		}
		Button(.localized("Create Blank"), systemImage: "doc.badge.plus") {
			_select(_manager.addBlank(name: .localized("New Entitlements")), push: true)
		}
		if let certEntitlements = _certificateEntitlements {
			Button(.localized("From Certificate"), systemImage: "checkmark.seal") {
				_select(_manager.add(name: .localized("From Certificate"), dict: certEntitlements), push: true)
			}
		}
		if let appEntitlements = _appEntitlements {
			Button(.localized("From App's Signature"), systemImage: "app.badge.checkmark") {
				_select(_manager.add(name: .localized("From App's Signature"), dict: appEntitlements), push: true)
			}
		}
	}
}

// MARK: - Extension: Sources
extension SigningEntitlementsView {
	private var _grantedEntitlements: [String: Any]? {
		PlistDiff.grantedEntitlements(for: certificate)
	}

	private var _certificateEntitlements: [String: Any]? {
		guard let dict = _grantedEntitlements, !dict.isEmpty else { return nil }
		return dict
	}

	private var _appEntitlements: [String: Any]? {
		guard
			let app,
			let appURL = Storage.shared.getAppDirectory(for: app),
			let executable = Bundle(url: appURL)?.executableURL
		else { return nil }
		return MachOEntitlements.read(forExecutableAt: executable)
	}
}

// MARK: - Extension: Selection
extension SigningEntitlementsView {
	private func _select(_ entry: EntitlementsFile, push: Bool = false) {
		bindingValue = _manager.fileURL(for: entry)
		guard push else { return }
		_pushedEntry = entry
		_isPushingNewEntry = true
	}

	/// Clears a selection pointing at a deleted file. Never auto selects a file can sit in the library unused.
	private func _syncSelection() {
		if let bindingValue, _manager.entry(for: bindingValue) == nil {
			self.bindingValue = nil
		}
	}
}
