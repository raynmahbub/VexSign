//
//  WatchLibraryView.swift
//  VexSignWatch
//
//  The library and the pending updates, as the iPhone last reported them. Read
//  only: opening or installing an app from a watch is not a thing iOS allows.
//

import SwiftUI

struct WatchLibraryView: View {
	@EnvironmentObject private var store: WatchSessionStore

	var body: some View {
		List {
			if !(store.snapshot?.updates ?? []).isEmpty {
				Section("Updates") {
					ForEach(store.snapshot?.updates ?? []) { update in
						VStack(alignment: .leading, spacing: 1) {
							Text(update.name)
								.font(.footnote.weight(.medium))
								.lineLimit(1)
							Text("\(update.installedVersion ?? "?") → \(update.availableVersion ?? "?")")
								.font(.caption2.monospacedDigit())
								.foregroundStyle(.orange)
						}
					}
				}
			}

			Section("Library") {
				if (store.snapshot?.library ?? []).isEmpty {
					Text("Nothing in the library yet.")
						.font(.caption2)
						.foregroundStyle(.secondary)
				} else {
					ForEach(store.snapshot?.library ?? []) { app in
						HStack(spacing: 6) {
							Image(systemName: app.signed ? "checkmark.seal.fill" : "app.dashed")
								.font(.caption2)
								.foregroundStyle(app.signed ? .green : .secondary)
							Text(app.name)
								.font(.footnote)
								.lineLimit(1)
							Spacer()
							Text(app.version)
								.font(.caption2.monospacedDigit())
								.foregroundStyle(.secondary)
						}
					}
				}
			}
		}
		.navigationTitle("Library")
	}
}
