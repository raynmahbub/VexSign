//
//  VexSignWatchComplication.swift
//  VexSignWatchWidgets
//
//  The watch complication: certificate days left, plus app/update counts in the
//  rectangular family. It reads the snapshot the watch app mirrored into the
//  shared app group, so the face renders even when the watch app has not run
//  since the last iPhone push.
//

import WidgetKit
import SwiftUI

// MARK: - Entry

struct WatchComplicationEntry: TimelineEntry {
	let date: Date
	let snapshot: CompanionSnapshot?
}

// MARK: - Provider

struct WatchComplicationProvider: TimelineProvider {
	func placeholder(in context: Context) -> WatchComplicationEntry {
		WatchComplicationEntry(date: Date(), snapshot: .placeholder)
	}

	func getSnapshot(in context: Context, completion: @escaping (WatchComplicationEntry) -> Void) {
		completion(
			WatchComplicationEntry(
				date: Date(),
				snapshot: WatchSnapshotStore.load() ?? .placeholder
			)
		)
	}

	func getTimeline(in context: Context, completion: @escaping (Timeline<WatchComplicationEntry>) -> Void) {
		let entry = WatchComplicationEntry(date: Date(), snapshot: WatchSnapshotStore.load())
		// The countdown only changes at midnight; the watch app reloads every
		// timeline whenever the phone pushes something new.
		completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(30 * 60))))
	}
}

// MARK: - View

struct WatchComplicationView: View {
	@Environment(\.widgetFamily) private var family
	let entry: WatchComplicationEntry

	var body: some View {
		switch family {
		case .accessoryCircular: circular
		case .accessoryRectangular: rectangular
		case .accessoryCorner: corner
		case .accessoryInline: inline
		default: rectangular
		}
	}

	private var circular: some View {
		Gauge(value: _progress) {
			EmptyView()
		} currentValueLabel: {
			Text(entry.snapshot?.status.certLabel ?? "—")
				.font(.system(size: 15, weight: .bold, design: .rounded))
				.minimumScaleFactor(0.5)
		}
		.gaugeStyle(.accessoryCircularCapacity)
		.tint(_tint)
	}

	private var rectangular: some View {
		VStack(alignment: .leading, spacing: 1) {
			HStack(spacing: 3) {
				Image(systemName: (entry.snapshot?.status.certRevoked ?? false) ? "xmark.seal.fill" : "checkmark.seal.fill")
					.font(.system(size: 10))
				Text("VexSign")
					.font(.system(size: 11, weight: .semibold))
			}
			.foregroundStyle(_tint)

			Text(entry.snapshot?.status.certSummary ?? "Waiting for iPhone")
				.font(.system(size: 13, weight: .bold))
				.lineLimit(1)

			Text(_detail)
				.font(.system(size: 11))
				.foregroundStyle(.secondary)
				.lineLimit(1)
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}

	private var corner: some View {
		Text(entry.snapshot?.status.certLabel ?? "—")
			.font(.system(size: 14, weight: .bold, design: .rounded))
			.foregroundStyle(_tint)
	}

	private var inline: some View {
		Text("VexSign \(entry.snapshot?.status.certLabel ?? "—")")
	}

	private var _detail: String {
		guard let status = entry.snapshot?.status else { return "Open VexSign on the watch" }
		return "\(status.installedApps) apps · \(status.pendingUpdates) updates"
	}

	private var _tint: Color {
		guard let status = entry.snapshot?.status else { return .secondary }
		if status.certRevoked { return .red }
		guard let days = status.certDaysRemaining else { return .secondary }
		if days < 7 { return .red }
		if days < 30 { return .orange }
		return .green
	}

	/// Fraction of a one-year profile still left, for the circular gauge.
	private var _progress: Double {
		guard let days = entry.snapshot?.status.certDaysRemaining else { return 0 }
		return min(max(Double(days) / 365.0, 0), 1)
	}
}

// MARK: - Widget

struct VexSignWatchComplication: Widget {
	let kind: String = "VexSignWatchComplication"

	var body: some WidgetConfiguration {
		StaticConfiguration(kind: kind, provider: WatchComplicationProvider()) { entry in
			WatchComplicationView(entry: entry)
				.containerBackground(.clear, for: .widget)
		}
		.configurationDisplayName("VexSign")
		.description("Certificate countdown and library counts from your iPhone.")
		.supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryCorner, .accessoryInline])
	}
}

// MARK: - Preview

#Preview(as: .accessoryRectangular) {
	VexSignWatchComplication()
} timeline: {
	WatchComplicationEntry(date: Date(), snapshot: .placeholder)
}
