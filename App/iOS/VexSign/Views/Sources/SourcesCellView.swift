//
//  SourcesCellView.swift
//  VexSign
//
//  Created by VexSign Contributors on 1.05.2025.
//

import SwiftUI
import NimbleViews
import NukeUI
import NimbleExtensions

// MARK: - View
struct SourcesCellView: View {
	@Environment(\.horizontalSizeClass) private var horizontalSizeClass

	var source: AltSource
	var isEditMode: Bool = false

	@State private var _isExcluded: Bool = false

	private var _sourceIdentifier: String {
		source.identifier ?? source.sourceURL?.absoluteString ?? ""
	}

	private var _isPremiumSource: Bool {
		guard let url = source.sourceURL else { return false }
		return VexSignAPI.isPremiumSource(url)
	}

	// MARK: Body
	var body: some View {
		let isRegular = horizontalSizeClass != .compact

		let cellContent = HStack {
		VexIconCellView(
			title: source.name ?? .localized("Unknown"),
			subtitle: _subtitle,
			iconUrl: source.iconURL
		)
			if SourcePreferences.isPinned(_sourceIdentifier) {
				Image(systemName: "pin.fill")
					.foregroundColor(.orange)
					.font(.caption2)
			}
			if _isPremiumSource {
				Image(systemName: "crown.fill")
					.foregroundColor(.yellow)
					.font(.caption)
			}
			if SourcePreferences.isTrusted(_sourceIdentifier) {
				Image(systemName: "checkmark.seal.fill")
					.foregroundStyle(.green)
					.font(.caption)
					.accessibilityLabel(Text(.localized("Trusted repository")))
			}
			if _isExcluded {
				Image(systemName: "eye.slash")
					.foregroundColor(.secondary)
					.font(.caption2)
			}
		}
		.onAppear { _isExcluded = VexSignAPI.isSourceExcluded(_sourceIdentifier) }
		.padding(isRegular ? 12 : 0)
		.background(
			isRegular
			? RoundedRectangle(cornerRadius: 18, style: .continuous)
				.fill(Color(.quaternarySystemFill))
			: nil
		)

		if isEditMode {
			cellContent
		} else {
			cellContent
				.swipeActions(edge: .trailing, allowsFullSwipe: false) {
					if !_isPremiumSource {
						_actions(for: source)
					}
					_excludeAction()
					_contextActions(for: source)
				}
				.contextMenu {
					_contextActions(for: source)
					_excludeAction()
					if !_isPremiumSource {
						Divider()
						_actions(for: source)
					}
				}
		}
	}
}

// MARK: - Extension: View
extension SourcesCellView {
	@ViewBuilder
	private func _actions(for source: AltSource) -> some View {
		Button(.localized("Delete"), systemImage: "trash", role: .destructive) {
			SourceRemoval.delete([source])
		}
	}

	private var _subtitle: String {
		if let error = SourcePreferences.lastError(for: _sourceIdentifier) {
			return error
		}
		if let date = SourcePreferences.lastFetch(for: _sourceIdentifier) {
			return "\(source.sourceURL?.host ?? "") · \(date.formatted(date: .omitted, time: .shortened))"
		}
		return source.sourceURL?.absoluteString ?? ""
	}

	@ViewBuilder
	private func _contextActions(for source: AltSource) -> some View {
		Button(.localized("Copy"), systemImage: "doc.on.clipboard") {
			UIPasteboard.general.string = source.sourceURL?.absoluteString
		}
		if let url = source.sourceURL {
			Button(.localized("Open in Browser"), systemImage: "safari") {
				UIApplication.open(url)
			}
		}
		Button(
			SourcePreferences.isPinned(_sourceIdentifier) ? .localized("Unpin") : .localized("Pin"),
			systemImage: SourcePreferences.isPinned(_sourceIdentifier) ? "pin.slash" : "pin"
		) {
			SourcePreferences.setPinned(_sourceIdentifier, pinned: !SourcePreferences.isPinned(_sourceIdentifier))
		}
		Button(
			SourcePreferences.isTrusted(_sourceIdentifier) ? .localized("Remove Trust") : .localized("Mark as Trusted"),
			systemImage: SourcePreferences.isTrusted(_sourceIdentifier) ? "checkmark.seal" : "checkmark.seal.fill"
		) {
			SourcePreferences.setTrusted(_sourceIdentifier, trusted: !SourcePreferences.isTrusted(_sourceIdentifier))
		}
		let automaticUpdateID = source.sourceURL?.absoluteString ?? _sourceIdentifier
		Button(
			SourcePreferences.autoUpdatesEnabled(for: automaticUpdateID)
				? .localized("Pause Automatic Updates")
				: .localized("Allow Automatic Updates"),
			systemImage: SourcePreferences.autoUpdatesEnabled(for: automaticUpdateID)
				? "pause.circle"
				: "play.circle"
		) {
			SourcePreferences.setAutoUpdatesEnabled(
				!SourcePreferences.autoUpdatesEnabled(for: automaticUpdateID),
				for: automaticUpdateID
			)
		}
	}

	@ViewBuilder
	private func _excludeAction() -> some View {
		Button {
			let newValue = !_isExcluded
			VexSignAPI.setSourceExcluded(_sourceIdentifier, excluded: newValue)
			_isExcluded = newValue
		} label: {
			Label(
				_isExcluded ? .localized("Show in All") : .localized("Hide from All"),
				systemImage: _isExcluded ? "eye" : "eye.slash"
			)
		}
		.tint(.orange)
	}
}

// MARK: - Extension: onAppear
extension SourcesCellView {
	func onAppearLoadExcluded() -> some View {
		self.onAppear {
			_isExcluded = VexSignAPI.isSourceExcluded(_sourceIdentifier)
		}
	}
}
