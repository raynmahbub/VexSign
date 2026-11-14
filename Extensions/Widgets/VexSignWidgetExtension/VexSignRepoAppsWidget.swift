//
//  VexSignRepoAppsWidget.swift
//  VexSignWidgetExtension
//
//  "Repository Apps" widget: the apps of the repositories you added, straight on
//  the Home Screen. Tap a row and VexSign opens that app's page in the App Store
//  tab. The extension reads `WidgetRepoPayload` (and the icon cache next to it)
//  from the app group — it never opens CoreData and never hits the network.
//

import WidgetKit
import SwiftUI
import AppIntents
import UIKit

// MARK: - Configuration

/// Which repository the widget shows, and in what order.
struct RepoAppsWidgetIntent: WidgetConfigurationIntent {
	static var title: LocalizedStringResource = "Repository Apps"
	static var description = IntentDescription("Choose the repository and the order the widget lists its apps in.")

	@Parameter(title: "Repository")
	var source: RepoSourceEntity?

	@Parameter(title: "Sort", default: .repositoryOrder)
	var sort: RepoAppSortOrder
}

enum RepoAppSortOrder: String, AppEnum {
	case repositoryOrder
	case name
	case updatesFirst

	static var typeDisplayRepresentation: TypeDisplayRepresentation = "Sort Order"
	static var caseDisplayRepresentations: [RepoAppSortOrder: DisplayRepresentation] = [
		.repositoryOrder: "Repository order",
		.name: "Name",
		.updatesFirst: "Updates first"
	]
}

/// A repository the app has published into the app group.
struct RepoSourceEntity: AppEntity {
	let url: String
	let name: String

	static let typeDisplayRepresentation: TypeDisplayRepresentation = "Repository"
	static let defaultQuery = RepoSourceQuery()

	var id: String { url }

	var displayRepresentation: DisplayRepresentation {
		DisplayRepresentation(title: "\(name)")
	}
}

struct RepoSourceQuery: EntityQuery {
	func entities(for identifiers: [String]) async throws -> [RepoSourceEntity] {
		let payload = WidgetRepoPayload.load() ?? .placeholder
		return identifiers.compactMap { url in
			payload.sources.first { $0.url == url }.map { RepoSourceEntity(url: $0.url, name: $0.name) }
		}
	}

	func suggestedEntities() async throws -> [RepoSourceEntity] {
		let payload = WidgetRepoPayload.load() ?? .placeholder
		// "All repositories" is the default (nil parameter), so only list real ones here.
		return payload.sources.map { RepoSourceEntity(url: $0.url, name: $0.name) }
	}

	func defaultResult() async -> RepoSourceEntity? {
		(try? await suggestedEntities())?.first
	}
}

// MARK: - Entry

struct RepoAppsEntry: TimelineEntry {
	let date: Date
	let sourceName: String?
	let apps: [WidgetRepoPayload.App]
	let isStale: Bool
}

// MARK: - Provider

struct RepoAppsProvider: AppIntentTimelineProvider {
	func placeholder(in context: Context) -> RepoAppsEntry {
		let payload = WidgetRepoPayload.placeholder
		return RepoAppsEntry(
			date: Date(),
			sourceName: payload.sources.first?.name,
			apps: payload.sources.first?.apps ?? [],
			isStale: false
		)
	}

	func snapshot(for configuration: RepoAppsWidgetIntent, in context: Context) async -> RepoAppsEntry {
		entry(for: configuration)
	}

	func timeline(for configuration: RepoAppsWidgetIntent, in context: Context) async -> Timeline<RepoAppsEntry> {
		let entry = self.entry(for: configuration)
		// The app reloads this timeline whenever a repository refreshes; the
		// hourly policy is only a safety net for a device that never opens VexSign.
		return Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(60 * 60)))
	}

	private func entry(for configuration: RepoAppsWidgetIntent) -> RepoAppsEntry {
		let payload = WidgetRepoPayload.load() ?? .placeholder
		let selectedURL = configuration.source?.url
		var apps = payload.apps(in: selectedURL)

		switch configuration.sort {
		case .repositoryOrder:
			break
		case .name:
			apps = apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
		case .updatesFirst:
			apps = apps.sorted { lhs, rhs in
				if lhs.hasUpdate != rhs.hasUpdate { return lhs.hasUpdate }
				return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
			}
		}

		return RepoAppsEntry(
			date: Date(),
			sourceName: selectedURL.flatMap { url in payload.sources.first { $0.url == url }?.name },
			apps: apps,
			isStale: payload.isStale
		)
	}
}

// MARK: - View

struct RepoAppsWidgetView: View {
	@Environment(\.widgetFamily) private var family
	let entry: RepoAppsEntry

	var body: some View {
		switch family {
		case .systemSmall: small
		case .accessoryRectangular: accessory
		default: list
		}
	}

	// MARK: Layouts

	private var small: some View {
		VStack(alignment: .leading, spacing: 6) {
			header

			if let first = entry.apps.first {
				Spacer(minLength: 0)
				HStack(spacing: 8) {
					IconView(file: first.iconFile, size: 34)
					VStack(alignment: .leading, spacing: 1) {
						Text(first.name)
							.font(.footnote.weight(.semibold))
							.lineLimit(1)
						Text(first.version)
							.font(.caption2)
							.foregroundStyle(.secondary)
							.lineLimit(1)
					}
				}
				Link(destination: Self.deepLink(for: first, sourceName: entry.sourceName)) {
					Text("Open in VexSign")
						.font(.caption2.weight(.semibold))
						.foregroundStyle(Color.accentColor)
				}
			} else {
				Spacer(minLength: 0)
				Text("No apps yet")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
		}
		.containerBackground(.fill.tertiary, for: .widget)
	}

	private var list: some View {
		VStack(alignment: .leading, spacing: 0) {
			header
				.padding(.bottom, 4)

			if entry.apps.isEmpty {
				emptyState
			} else {
				ForEach(entry.apps.prefix(family == .systemMedium ? 3 : 6)) { app in
					Link(destination: Self.deepLink(for: app, sourceName: entry.sourceName)) {
						HStack(spacing: 10) {
							IconView(file: app.iconFile, size: family == .systemMedium ? 30 : 34)

							VStack(alignment: .leading, spacing: 1) {
								Text(app.name)
									.font(.footnote.weight(.semibold))
									.lineLimit(1)
								Text(app.bundleID)
									.font(.caption2)
									.foregroundStyle(.secondary)
									.lineLimit(1)
							}

							Spacer(minLength: 4)

							if app.hasUpdate {
								Image(systemName: "arrow.up.circle.fill")
									.font(.footnote)
									.foregroundStyle(.orange)
							}

							Text(app.version)
								.font(.caption2)
								.foregroundStyle(.secondary)
								.lineLimit(1)
						}
						.padding(.vertical, family == .systemMedium ? 4 : 5)
					}
					.buttonStyle(.plain)

					if app.id != entry.apps.prefix(family == .systemMedium ? 3 : 6).last?.id {
						Divider()
					}
				}
			}

			Spacer(minLength: 0)
		}
		.containerBackground(.fill.tertiary, for: .widget)
	}

	private var accessory: some View {
		VStack(alignment: .leading, spacing: 2) {
			Text(entry.sourceName ?? "Repositories")
				.font(.caption2.weight(.semibold))
				.lineLimit(1)
			Text("^[\(entry.apps.count) apps](inflect: true)")
				.font(.title3.bold())
				.contentTransition(.numericText())
			if let updates = updateCount, updates > 0 {
				Text("^[\(updates) updates](inflect: true)")
					.font(.caption2)
			}
		}
		.containerBackground(.fill.tertiary, for: .widget)
	}

	// MARK: Pieces

	private var header: some View {
		HStack(spacing: 4) {
			Image(systemName: "square.grid.2x2.fill")
				.font(.caption2)
				.foregroundStyle(Color.accentColor)
			Text(entry.sourceName ?? "All repositories")
				.font(.caption2.weight(.semibold))
				.lineLimit(1)
			Spacer(minLength: 0)
			if entry.isStale {
				Image(systemName: "clock.arrow.circlepath")
					.font(.caption2)
					.foregroundStyle(.secondary)
			}
		}
	}

	private var emptyState: some View {
		VStack(alignment: .leading, spacing: 2) {
			Text("Nothing to show")
				.font(.footnote.weight(.semibold))
			Text("Add a repository in VexSign, then reopen it so the widget can fill.")
				.font(.caption2)
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)
		}
		.padding(.top, 4)
	}

	private var updateCount: Int? {
		let count = entry.apps.filter { $0.hasUpdate }.count
		return count
	}

	/// `vexsign://repo-app` is handled in `VexSignApp._handleURL`, which hands the
	/// id to `AppNavigationManager` — the same path a search result uses.
	static func deepLink(for app: WidgetRepoPayload.App, sourceName: String?) -> URL {
		var components = URLComponents()
		components.scheme = "vexsign"
		components.host = "repo-app"
		components.queryItems = [
			URLQueryItem(name: "id", value: app.id),
			URLQueryItem(name: "name", value: app.name),
			URLQueryItem(name: "source", value: sourceName)
		]
		return components.url ?? URL(string: "vexsign://appStore")!
	}
}

/// Icons come from the app group cache the app filled; a missing file falls back
/// to the placeholder, because the extension must not start a download.
struct IconView: View {
	let file: String?
	let size: CGFloat

	var body: some View {
		Group {
			if let file,
			   let folder = WidgetRepoPayload.iconCacheURL,
			   let image = UIImage(contentsOfFile: folder.appendingPathComponent(file).path) {
				Image(uiImage: image)
					.resizable().scaledToFill()
			} else {
				Image(systemName: "app.dashed")
					.font(.system(size: size * 0.45))
					.foregroundStyle(.secondary)
					.frame(width: size, height: size)
					.background(Color.secondary.opacity(0.15))
			}
		}
		.frame(width: size, height: size)
		.clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
	}
}

// MARK: - Widget

struct VexSignRepoAppsWidget: Widget {
	let kind: String = "VexSignRepoAppsWidget"

	var body: some WidgetConfiguration {
		AppIntentConfiguration(kind: kind, intent: RepoAppsWidgetIntent.self, provider: RepoAppsProvider()) { entry in
			RepoAppsWidgetView(entry: entry)
		}
		.configurationDisplayName("Repository Apps")
		.description("The apps in your repositories, with an update badge. Tap to open one in VexSign.")
		.supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular])
	}
}

// MARK: - Preview

#Preview(as: .systemMedium) {
	VexSignRepoAppsWidget()
} timeline: {
	RepoAppsEntry(
		date: Date(),
		sourceName: "Example Repository",
		apps: WidgetRepoPayload.placeholder.sources[0].apps,
		isStale: false
	)
}
