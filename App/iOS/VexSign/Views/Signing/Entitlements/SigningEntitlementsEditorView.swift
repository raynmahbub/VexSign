//
//  SigningEntitlementsEditorView.swift
//  VexSign
//
//  Created by VexSign Team
//

import SwiftUI
import NimbleViews
import NimbleExtensions

// MARK: - View
struct SigningEntitlementsEditorView: View {
	let entry: EntitlementsFile
	var certificate: CertificatePair?

	@ObservedObject private var _manager = EntitlementsManager.shared
	@ObservedObject private var _clipboard = PlistClipboard.shared

	@State private var _dict: [String: Any] = [:]
	@State private var _hasLoaded = false
	@State private var _query = ""
	@State private var _isAddingPresenting = false
	@State private var _addKind: PlistValueKind = .string
	@State private var _showsRaw = false
	@State private var _editMode: EditMode = .inactive
	@State private var _selectedKeys: Set<String> = []
	@State private var _confirmDeleteSelection = false
	@State private var _confirmDeleteEntry = false
	@State private var _keyToDelete: String?
	@State private var _flaggedOnly = false
	@State private var _detailKey: String?

	private var _grantedEntitlements: [String: Any]? {
		PlistDiff.grantedEntitlements(for: certificate)
	}

	private var _reference: PlistEntryReference? {
		guard let granted = _grantedEntitlements else { return nil }
		return PlistEntryReference(
			values: granted,
			missingNote: .localized("Not granted by the selected certificate's provisioning profile"),
			mismatchNote: .localized("Value differs from the selected certificate's provisioning profile"),
			resetTitle: .localized("Reset to Certificate Value")
		)
	}

	private var _flaggedCount: Int {
		PlistDiff.flaggedCount(in: _dict, against: _grantedEntitlements)
	}

	/// Keys whose value differs from the certificate's — the only ones "Reset" has something to reset to.
	private var _mismatchedKeys: [String] {
		guard let granted = _grantedEntitlements else { return [] }
		return _dict.keys.filter { PlistDiff.match(key: $0, value: _dict[$0]!, against: granted) == .differs }
	}

	private var _detailMatch: PlistDiff.Match? {
		guard let _detailKey, let value = _dict[_detailKey], let granted = _grantedEntitlements else { return nil }
		return PlistDiff.match(key: _detailKey, value: value, against: granted)
	}

	private var _keys: [String] {
		var all = _dict.keys.sorted()
		// `_flaggedCount > 0` guard: without it, resetting the last mismatch while filtered
		// leaves the toggle on with nothing left to show and no indication why.
		if _flaggedOnly, _flaggedCount > 0, let granted = _grantedEntitlements {
			all = all.filter { PlistDiff.match(key: $0, value: _dict[$0]!, against: granted) != .matches }
		}
		guard !_query.isEmpty else { return all }
		return all.filter { $0.localizedCaseInsensitiveContains(_query) }
	}

	private var _otherFiles: [EntitlementsFile] {
		_manager.files.filter { $0.id != entry.id }
	}

	// MARK: Body
	var body: some View {
		NBList(.localized("Entries")) {
			ForEach(_keys, id: \.self) { key in
				_row(for: key)
			}
		}
		.searchable(
			text: $_query,
			placement: .navigationBarDrawer(displayMode: .automatic),
			prompt: Text(.localized("Search Entitlements"))
		)
		.dismissableKeyboard()
		.toolbar {
			_toolbar
		}
		.environment(\.editMode, $_editMode)
		.navigationDestination(isPresented: $_isAddingPresenting) {
			if _showsRaw {
				PlistRawEditorView(dict: _dict) { dict in
					_dict = dict
					_save()
				}
			} else {
				PlistEntryEditView(
					originalKey: nil,
					kind: _addKind,
					value: _addKind.emptyValue,
					reference: _reference
				) { key, value in
					_dict[key] = value
					_save()
				}
			}
		}
		.confirmationDialog(.localized("Delete selected entitlements?"), isPresented: $_confirmDeleteSelection, titleVisibility: .visible) {
			Button(.localized("Delete"), role: .destructive) {
				_delete(_selectedKeys)
				_toggleSelectMode()
			}
			Button(.localized("Cancel"), role: .cancel) {}
		} message: {
			Text(String.localized("This permanently removes %lld selected key(s) from this custom entitlements file.", arguments: _selectedKeys.count))
		}
		.confirmationDialog(.localized("Delete entitlement?"), isPresented: $_confirmDeleteEntry, titleVisibility: .visible) {
			Button(.localized("Delete"), role: .destructive) {
				if let key = _keyToDelete { _delete([key]) }
				_keyToDelete = nil
			}
			Button(.localized("Cancel"), role: .cancel) { _keyToDelete = nil }
		} message: {
			Text(_keyToDelete ?? "")
		}
		.confirmationDialog(
			_detailKey ?? "",
			isPresented: Binding(get: { _detailKey != nil }, set: { if !$0 { _detailKey = nil } }),
			titleVisibility: .visible
		) {
			if _detailMatch == .differs, let key = _detailKey {
				Button(.localized("Reset to Certificate Value")) {
					_resetToCertificateValue(key)
				}
			}
			Button(.localized("Cancel"), role: .cancel) {}
		} message: {
			Text(_detailMatch == .missing
				? .localized("Not granted by the selected certificate's provisioning profile")
				: .localized("Value differs from the selected certificate's provisioning profile"))
		}
		.onAppear(perform: _load)
	}
}

// MARK: - Extension: Toolbar
extension SigningEntitlementsEditorView {
	@ToolbarContentBuilder
	private var _toolbar: some ToolbarContent {
		ToolbarItem(placement: .topBarLeading) {
			Button(_editMode.isEditing ? .localized("Done") : .localized("Select")) {
				_toggleSelectMode()
			}
		}
		if _editMode.isEditing {
			ToolbarItem(placement: .topBarTrailing) {
				Button(role: .destructive) {
					_confirmDeleteSelection = true
				} label: {
					Label(.localized("Delete"), systemImage: "trash")
				}
				.disabled(_selectedKeys.isEmpty)
				.accessibilityIdentifier("Entitlements.deleteSelected")
			}
			NBToolbarMenu(
				systemImage: "ellipsis.circle",
				style: .icon,
				placement: .topBarTrailing
			) {
				_selectionActions
			}
		} else {
			ToolbarItem(placement: .topBarTrailing) {
				Button {
					_flaggedOnly.toggle()
				} label: {
					Image(systemName: "line.3.horizontal.decrease")
						.foregroundStyle(_flaggedCount == 0 ? Color.secondary : (_flaggedOnly ? Color.accentColor : Color.primary))
				}
				.disabled(_flaggedCount == 0)
			}
			NBToolbarMenu(
				systemImage: "plus",
				style: .icon,
				placement: .topBarTrailing
			) {
				_addMenu
			}
		}
	}

	@ViewBuilder
	private var _selectionActions: some View {
		Button(.localized("Copy"), systemImage: "doc.on.doc") {
			_clipboard.set(_dict.filter { _selectedKeys.contains($0.key) })
			_toggleSelectMode()
		}
		.disabled(_selectedKeys.isEmpty)

		Button(.localized("Reset to Certificate Value"), systemImage: "arrow.uturn.backward") {
			_resetToCertificateValues(_selectedKeys)
			_toggleSelectMode()
		}
		.disabled(_selectedKeys.isDisjoint(with: _mismatchedKeys))

		Button(.localized("Delete"), systemImage: "trash", role: .destructive) {
			_confirmDeleteSelection = true
		}
		.disabled(_selectedKeys.isEmpty)

		Divider()

		Button(.localized("Select All"), systemImage: "checkmark.circle") {
			_selectedKeys = Set(_keys)
		}
		Button(.localized("Deselect All"), systemImage: "circle") {
			_selectedKeys.removeAll()
		}
		.disabled(_selectedKeys.isEmpty)
	}

	@ViewBuilder
	private var _addMenu: some View {
		Button(.localized("Add Entry"), systemImage: "plus") {
			_present(.string)
		}
		Button(.localized("Add Dictionary"), systemImage: "curlybraces") {
			_present(.dictionary)
		}
		Button(.localized("Add Array"), systemImage: "list.bullet") {
			_present(.array)
		}
		Menu(.localized("Add Preset")) {
			ForEach(EntitlementsPreset.allCases) { preset in
				Button(preset.name) {
					_dict = preset.merging(into: _dict)
					_save()
				}
			}
		}
		if !_otherFiles.isEmpty {
			Menu(.localized("Merge From Library")) {
				ForEach(_otherFiles) { other in
					Button(other.name) {
						_merge(_manager.load(other))
					}
				}
			}
		}
		Button(.localized("Import File"), systemImage: "square.and.arrow.down") {
			DocumentPicker.open([.xmlPropertyList, .plist, .entitlements, .mobileProvision, .json], folder: .entitlements) { urls in
				guard let url = urls.first else { return }
				_importMerge(from: url)
			}
		}
		if !_clipboard.entries.isEmpty {
			Button(.localized("Paste"), systemImage: "doc.on.clipboard") {
				_merge(_clipboard.entries)
			}
		}
		Divider()

		Button(.localized("Edit Raw"), systemImage: "chevron.left.forwardslash.chevron.right") {
			_showsRaw = true
			_isAddingPresenting = true
		}

		if !_mismatchedKeys.isEmpty {
			Button(.localized("Reset All Mismatched"), systemImage: "arrow.triangle.2.circlepath") {
				_resetAllMismatched()
			}
		}
	}

	private func _present(_ kind: PlistValueKind) {
		_showsRaw = false
		_addKind = kind
		_isAddingPresenting = true
	}

	private func _toggleSelectMode() {
		withAnimation {
			_editMode = _editMode.isEditing ? .inactive : .active
			if !_editMode.isEditing { _selectedKeys.removeAll() }
		}
	}

	private func _merge(_ incoming: [String: Any]) {
		guard !incoming.isEmpty else { return }
		_dict.merge(incoming) { _, incomingValue in incomingValue }
		_save()
	}

	private func _importMerge(from url: URL) {
		guard let dict = EntitlementsManager.parseEntitlements(from: url) else {
			Toast.error(.localized("Couldn't read entitlements from that file"))
			return
		}
		_merge(dict)
	}

	private func _resetToCertificateValue(_ key: String) {
		_resetToCertificateValues([key])
	}

	private func _resetAllMismatched() {
		_resetToCertificateValues(Set(_mismatchedKeys))
	}

	private func _resetToCertificateValues(_ keys: Set<String>) {
		guard let granted = _grantedEntitlements else { return }
		for key in keys where granted[key] != nil {
			_dict[key] = granted[key]
		}
		_save()
	}

	private func _delete(_ keys: Set<String>) {
		keys.forEach { _dict.removeValue(forKey: $0) }
		_save()
	}
}

// MARK: - Extension: Rows
extension SigningEntitlementsEditorView {
	@ViewBuilder
	private func _row(for key: String) -> some View {
		if let value = _dict[key] {
			if _editMode.isEditing {
				_selectableRow(key: key, value: value)
			} else {
				_editableRow(key: key, value: value)
			}
		}
	}

	@ViewBuilder
	private func _selectableRow(key: String, value: Any) -> some View {
		let isSelected = _selectedKeys.contains(key)

		Button {
			if isSelected { _selectedKeys.remove(key) } else { _selectedKeys.insert(key) }
		} label: {
			HStack {
				Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
					.foregroundStyle(isSelected ? Color.accentColor : .secondary)
				PlistValueRow(key: key, value: value)
			}
		}
		.buttonStyle(.plain)
	}

	@ViewBuilder
	private func _editableRow(key: String, value: Any) -> some View {
		HStack(spacing: 8) {
			Group {
				if let kind = PlistValueKind.kind(for: value) {
					HStack {
						NavigationLink {
							if kind.isContainer {
								PlistNodeView(title: key, value: value) { newValue in
									_dict[key] = newValue
									_save()
								}
							} else {
								PlistEntryEditView(
									originalKey: key,
								kind: kind,
								value: value,
								reference: _reference
								) { newKey, newValue in
									if newKey != key { _dict.removeValue(forKey: key) }
									_dict[newKey] = newValue
									_save()
								}
							}
						} label: {
							PlistValueRow(key: key, value: value)
						}
						_matchButton(key: key, value: value)
					}
				} else {
					CertificatesInfoEntitlementCellView(key: key, value: value)
				}
			}

			Button(role: .destructive) {
				_keyToDelete = key
				_confirmDeleteEntry = true
			} label: {
				Image(systemName: "trash")
			}
			.buttonStyle(.plain)
			.accessibilityLabel(.localized("Delete"))
			.accessibilityIdentifier("Entitlements.delete.\(key)")
		}
		.swipeActions(edge: .trailing, allowsFullSwipe: false) {
			Button(role: .destructive) {
				_delete([key])
			} label: {
				Label(.localized("Delete"), systemImage: "trash")
			}
		}
	}

	/// A sibling of the row's NavigationLink, never nested in its label — nested buttons there don't reliably receive taps.
	@ViewBuilder
	private func _matchButton(key: String, value: Any) -> some View {
		if let granted = _grantedEntitlements {
			let match = PlistDiff.match(key: key, value: value, against: granted)
			if match != .matches {
				Button {
					_detailKey = key
				} label: {
					Image(systemName: match == .missing ? "exclamationmark.triangle.fill" : "arrow.triangle.2.circlepath.circle.fill")
						.foregroundStyle(match == .missing ? .orange : .blue)
				}
				.buttonStyle(.plain)
			}
		}
	}
}

// MARK: - Extension: Persistence
extension SigningEntitlementsEditorView {
	private func _load() {
		guard !_hasLoaded else { return }
		_dict = _manager.load(entry)
		_hasLoaded = true
	}

	private func _save() {
		guard !_manager.save(entry, dict: _dict) else { return }
		Toast.error(.localized("Couldn't save these entitlements. Your last change was not stored."))
	}
}

// MARK: - Entitlements Presets
/// Curated entitlement bundles people add over and over when signing. Each merges
/// its keys into the current entitlements dict; existing keys win over preset ones.
enum EntitlementsPreset: String, CaseIterable, Identifiable {
	case performance
	case appGroups
	case siri
	case pushDevelopment
	case gameCenter
	case networkInfo
	case timeSensitiveNotifications
	case deviceName

	var id: String { rawValue }

	var name: String {
		switch self {
		case .performance: .localized("Memory & Performance")
		case .appGroups: .localized("App Groups")
		case .siri: .localized("Siri")
		case .pushDevelopment: .localized("Push Notifications (Development)")
		case .gameCenter: .localized("Game Center")
		case .networkInfo: .localized("Network & Wi-Fi Info")
		case .timeSensitiveNotifications: .localized("Time-Sensitive Notifications")
		case .deviceName: .localized("Device Name Access")
		}
	}

	/// Adds this preset's keys to `existing` without replacing a value that is already there —
	/// the rule stated above. The Add Preset menu used the editor's general merge, where the
	/// incoming value wins, so adding "App Groups" replaced the user's own group list with the
	/// placeholder one.
	func merging(into existing: [String: Any]) -> [String: Any] {
		existing.merging(values) { current, _ in current }
	}

	var values: [String: Any] {
		switch self {
		case .performance:
			return [
				"com.apple.developer.kernel.extended-virtual-addressing": true,
				"com.apple.developer.kernel.increased-memory-limit": true
			]
		case .appGroups:
			return [
				"com.apple.security.application-groups": ["group.com.vexsign.shared"]
			]
		case .siri:
			return [
				"com.apple.developer.siri": true
			]
		case .pushDevelopment:
			return [
				"aps-environment": "development"
			]
		case .gameCenter:
			return [
				"com.apple.developer.game-center": true
			]
		case .networkInfo:
			return [
				"com.apple.developer.networking.wifi-info": true,
				"com.apple.external-accessory.wireless-configuration": true
			]
		case .timeSensitiveNotifications:
			return [
				"com.apple.developer.usernotifications.time-sensitive": true
			]
		case .deviceName:
			return [
				"com.apple.developer.device-information.user-assigned-device-name": true
			]
		}
	}
}
