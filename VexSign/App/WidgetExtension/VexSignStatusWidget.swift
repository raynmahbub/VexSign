//
//  VexSignStatusWidget.swift
//  VexSignWidgetExtension
//
//  Home Screen status widget: certificate days remaining, pending updates and the
//  library count. Reads the app-group payload the app writes
//  (`WidgetStatusPayload`); the extension never opens CoreData.
//

import WidgetKit
import SwiftUI

// MARK: - Entry

struct VexSignStatusEntry: TimelineEntry {
	let date: Date
	let payload: WidgetStatusPayload
}

// MARK: - Provider

struct VexSignStatusProvider: TimelineProvider {
	func placeholder(in context: Context) -> VexSignStatusEntry {
		VexSignStatusEntry(date: Date(), payload: .placeholder)
	}

	func getSnapshot(in context: Context, completion: @escaping (VexSignStatusEntry) -> Void) {
		completion(VexSignStatusEntry(date: Date(), payload: WidgetStatusPayload.load() ?? .placeholder))
	}

	func getTimeline(in context: Context, completion: @escaping (Timeline<VexSignStatusEntry>) -> Void) {
		let payload = WidgetStatusPayload.load() ?? .placeholder
		let entry = VexSignStatusEntry(date: Date(), payload: payload)

		// The countdown only moves at midnight, but the app pushes reloads whenever
		// state changes; 30 minutes is just the safety net.
		completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(30 * 60))))
	}
}

// MARK: - View

struct VexSignStatusWidgetView: View {
	@Environment(\.widgetFamily) private var family
	let entry: VexSignStatusEntry

	var body: some View {
		switch family {
		case .systemSmall: small
		default: medium
		}
	}

	private var small: some View {
		VStack(alignment: .leading, spacing: 6) {
			header

			Spacer(minLength: 0)

			Text(entry.payload.certLabel)
				.font(.system(size: 34, weight: .bold, design: .rounded))
				.foregroundStyle(entry.payload.certTint)
				.contentTransition(.numericText())

			Text("Certificate")
				.font(.caption2)
				.foregroundStyle(.secondary)
				.lineLimit(1)

			footer
		}
		.containerBackground(.fill.tertiary, for: .widget)
	}

	private var medium: some View {
		HStack(spacing: 14) {
			column(
				title: "Cert",
				value: entry.payload.certLabel,
				tint: entry.payload.certTint
			)

			Divider()

			column(
				title: "Updates",
				value: "\(entry.payload.pendingUpdates)",
				tint: entry.payload.updatesTint
			)

			Divider()

			column(
				title: "Apps",
				value: "\(entry.payload.installedCount)",
				tint: .primary
			)
		}
		.containerBackground(.fill.tertiary, for: .widget)
	}

	private var header: some View {
		HStack(spacing: 4) {
			Image(systemName: entry.payload.certRevoked ? "xmark.seal.fill" : "checkmark.seal.fill")
				.foregroundStyle(entry.payload.certTint)
			Text(entry.payload.certName ?? "No Certificate")
				.font(.caption2.weight(.semibold))
				.lineLimit(1)
		}
	}

	private var footer: some View {
		Text("^\(entry.payload.pendingUpdates) updates")
			.font(.caption2)
			.foregroundStyle(entry.payload.updatesTint)
			.lineLimit(1)
	}

	private func column(title: String, value: String, tint: Color) -> some View {
		VStack(alignment: .leading, spacing: 4) {
			Text(title)
				.font(.caption2)
				.foregroundStyle(.secondary)
			Text(value)
				.font(.title3.bold())
				.foregroundStyle(tint)
				.contentTransition(.numericText())
			Spacer(minLength: 0)
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}
}

// MARK: - Widget

struct VexSignStatusWidget: Widget {
	let kind: String = "VexSignStatusWidget"

	var body: some WidgetConfiguration {
		StaticConfiguration(kind: kind, provider: VexSignStatusProvider()) { entry in
			VexSignStatusWidgetView(entry: entry)
		}
		.configurationDisplayName("VexSign Status")
		.description("Certificate countdown, pending updates and library size.")
		.supportedFamilies([.systemSmall, .systemMedium])
	}
}

// MARK: - Preview

#Preview(as: .systemMedium) {
	VexSignStatusWidget()
} timeline: {
	VexSignStatusEntry(date: Date(), payload: .placeholder)
}
