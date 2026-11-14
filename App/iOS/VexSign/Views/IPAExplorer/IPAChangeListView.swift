//
//  IPAChangeListView.swift
//  VexSign
//
//  "What changed" for the IPA Explorer: every recorded edit with a per-file undo, and a
//  "Discard Changes" that rolls the whole bundle back to how it opened.
//

import SwiftUI
import NimbleViews
import NimbleExtensions

@MainActor
struct IPAChangeListView: View {
	@Environment(\.dismiss) private var dismiss

	@ObservedObject private var _workspace: IPAWorkspace

	private let _journal: IPAChangeJournal

	init(workspace: IPAWorkspace, journal: IPAChangeJournal) {
		self._workspace = workspace
		self._journal = journal
	}

	var body: some View {
		NBList(.localized("Recent Changes")) {
			if _journal.changes.isEmpty {
				Section {
					Text(.localized("No changes yet."))
						.foregroundStyle(.secondary)
						.listRowBackground(Color.clear)
				}
			} else {
				Section {
					ForEach(_journal.changes.reversed()) { change in
						_row(change)
					}
				} footer: {
					Text(.localized("Undo restores a file to how it was before that change. Changes are recorded until you rebuild the IPA, which starts a clean history."))
				}

				Section {
					Button(role: .destructive) {
						_discardAll()
					} label: {
						Label(.localized("Discard All Changes"), systemImage: "arrow.uturn.backward.circle")
					}
				}
			}
		}
	}

	@ViewBuilder
	private func _row(_ change: IPAChange) -> some View {
		HStack(spacing: 12) {
			Image(systemName: change.symbol)
				.foregroundStyle(_tint(change))
				.frame(width: 22)

			VStack(alignment: .leading, spacing: 1) {
				Text(change.relativePath)
					.font(.subheadline)
					.lineLimit(1)
					.truncationMode(.middle)
				Text(verbatim: "\(change.title) · \(change.date.formatted(date: .omitted, time: .shortened))")
					.font(.caption)
					.foregroundStyle(.secondary)
			}

			Spacer()

			Button(.localized("Undo")) {
				_undo(change)
			}
			.font(.subheadline.bold())
			.buttonStyle(.borderless)
			.tint(.accentColor)
		}
	}

	private func _tint(_ change: IPAChange) -> Color {
		switch change.kind {
		case .added: .green
		case .modified: .orange
		case .removed: .red
		}
	}

	private func _undo(_ change: IPAChange) {
		let target = _workspace.containerURL.appendingPathComponent(change.relativePath)
		if _workspace.undoChange(at: target) {
			Toast.success(.localized("Undone"), systemImage: "arrow.uturn.backward")
		} else {
			Toast.error(.localized("Could not undo that change"), duration: .long)
		}
	}

	private func _discardAll() {
		DestructiveConfirm.present(
			title: .localized("Discard All Changes?"),
			message: .localized("Every file in this workspace is rolled back to how it looked when you opened it. There is no undo for this.")
		) {
			let reverted = _workspace.discardChanges()
			Toast.info(
				String.localized("%lld files reverted", arguments: reverted),
				systemImage: "arrow.uturn.backward"
			)
			dismiss()
		}
	}
}
