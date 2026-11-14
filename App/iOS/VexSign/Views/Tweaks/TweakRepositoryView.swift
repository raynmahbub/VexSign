//
//  TweakRepositoryView.swift
//  VexSign
//
//  Add and refresh user-supplied tweak feeds without treating remote content as
//  trusted code. Downloads are HTTPS-only and each file is still shown in the
//  normal Tweak Manager before it can be selected for signing.
//

import SwiftUI
import UIKit
import NimbleViews
import NimbleExtensions

struct TweakRepositoryView: View {
	@Environment(\.dismiss) private var dismiss
	@ObservedObject private var manager = TweakManager.shared
	@State private var urlText = ""
	@State private var isWorking = false

	var body: some View {
		NBList(.localized("Tweak Repositories")) {
			Section {
				TextField(.localized("HTTPS repository URL"), text: $urlText)
					.keyboardType(.URL)
					.textInputAutocapitalization(.never)
					.autocorrectionDisabled()

				Button {
					add()
				} label: {
					HStack {
						Label(.localized("Add and Import"), systemImage: "arrow.down.circle")
						Spacer()
						if isWorking { ProgressView() }
					}
				}
				.disabled(isWorking || URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)) == nil)
			} footer: {
				Text(.localized("A repository is a JSON feed containing tweak names and HTTPS download URLs. VexSign does not execute or inject a downloaded file until you choose it in the normal signing flow."))
			}

			if !manager.repositories.isEmpty {
				Section(.localized("Added Repositories")) {
					ForEach(manager.repositories) { repository in
						VStack(alignment: .leading, spacing: 4) {
							HStack {
								Text(repository.name).font(.body.weight(.medium))
								Spacer()
								Text(String.localized("%lld imported", arguments: repository.importedCount))
									.font(.caption)
									.foregroundStyle(.secondary)
							}
							Text(repository.url.absoluteString)
								.font(.caption)
								.foregroundStyle(.secondary)
								.lineLimit(1)
							if let date = repository.lastFetched {
								Text(String.localized("Updated %@", arguments: date.formatted(date: .abbreviated, time: .shortened)))
									.font(.caption2)
									.foregroundStyle(.tertiary)
							}
						}
						.contextMenu {
							Button(.localized("Refresh"), systemImage: "arrow.clockwise") { refresh(repository) }
							Button(.localized("Copy URL"), systemImage: "doc.on.doc") { UIPasteboard.general.string = repository.url.absoluteString }
							Button(.localized("Remove"), systemImage: "trash", role: .destructive) { manager.removeRepository(repository.id) }
						}
					}
				}
			}
		}
		.toolbar {
			ToolbarItem(placement: .cancellationAction) {
				Button(.localized("Done")) { dismiss() }
			}
		}
	}

	private func add() {
		guard let url = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
		isWorking = true
		Task {
			do {
				let count = try await manager.addRepository(url)
				await MainActor.run {
					isWorking = false
					urlText = ""
					Toast.success(String.localized("Imported %lld tweaks", arguments: count), systemImage: "wrench.and.screwdriver.fill")
				}
			} catch {
				await MainActor.run {
					isWorking = false
					Toast.error(error.localizedDescription, duration: .sticky)
				}
			}
		}
	}

	private func refresh(_ repository: TweakRepository) {
		urlText = repository.url.absoluteString
		add()
	}
}
