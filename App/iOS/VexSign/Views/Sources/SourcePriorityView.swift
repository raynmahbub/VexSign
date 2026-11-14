//
//  SourcePriorityView.swift
//  VexSign
//
//  User-controlled repository precedence. This is used both for the App Store
//  catalog and for duplicate resolution in the repository browser.
//

import SwiftUI
import AltSourceKit
import NimbleViews
import NimbleExtensions

struct SourcePriorityView: View {
	private let sourcesByID: [String: AltSource]
	@State private var order: [String]

	init(sources: [AltSource]) {
		let ids = sources.map { $0.identifier ?? $0.sourceURL?.absoluteString ?? "" }
		self.sourcesByID = sources.reduce(into: [:]) { result, source in
			let id = source.identifier ?? source.sourceURL?.absoluteString ?? ""
			result[id] = source
		}
		self._order = State(initialValue: SourcePreferences.order(for: ids))
	}

	var body: some View {
		List {
			Section {
				ForEach(order, id: \.self) { id in
					if let source = sourcesByID[id] {
						HStack(spacing: 12) {
							Image(systemName: "line.3.horizontal")
								.foregroundStyle(.tertiary)
							VStack(alignment: .leading, spacing: 2) {
								Text(source.name ?? .localized("Unknown Repository"))
									.font(.body.weight(.medium))
								Text(source.sourceURL?.host ?? source.sourceURL?.absoluteString ?? "")
									.font(.caption)
									.foregroundStyle(.secondary)
							}
							Spacer()
							if SourcePreferences.isTrusted(id) {
								Image(systemName: "checkmark.seal.fill")
									.foregroundStyle(.green)
							}
						}
					}
				}
				.onMove { offsets, destination in
					order.move(fromOffsets: offsets, toOffset: destination)
					SourcePreferences.setOrder(order)
				}
			} header: {
				Text(.localized("First match wins"))
			} footer: {
				Text(.localized("When the same app is published by multiple repositories, VexSign keeps the first entry in this list when duplicate hiding is enabled. Pinning only affects presentation; it does not change this order."))
			}
		}
		.navigationTitle(.localized("Repository Priority"))
		.navigationBarTitleDisplayMode(.inline)
		.toolbar { EditButton() }
	}
}
