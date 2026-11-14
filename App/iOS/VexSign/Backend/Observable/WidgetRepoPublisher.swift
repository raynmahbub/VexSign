//
//  WidgetRepoPublisher.swift
//  VexSign
//
//  Fills the "Repository Apps" widget: it snapshots the repositories that are
//  already loaded in `SourcesViewModel`, marks the apps that have an update, and
//  pre-fetches their icons into the app group so the extension never needs the
//  network. Runs off the main actor apart from the reads it starts from.
//

import Foundation
import SwiftUI
import UIKit
import WidgetKit
import OSLog
import NimbleExtensions

/// Not actor-isolated as a whole: only the snapshot reads need the main actor,
/// and the icon downloads should not run there.
enum WidgetRepoPublisher {
	static let widgetKind = "VexSignRepoAppsWidget"

	/// Icons are tiny, but a repository can list hundreds of apps; this bounds a
	/// single publish pass so refreshing a big source cannot stall the app.
	private static let _maxIconFetches = 24
	private static let _iconFetchConcurrency = 6
	private static let _maxIconBytes = 512 * 1024

	@MainActor
	private static var _inFlight: Task<Void, Never>?

	/// Rebuilds the payload and reloads the widget. Safe to call often: only one
	/// pass runs at a time and a newer call replaces a pending one.
	@MainActor
	static func publish() {
		_inFlight?.cancel()
		_inFlight = Task { await _publish() }
	}

	// MARK: - Pass

	@MainActor
	private static func _publish() async {
		// Game Mode means "no network": the widget keeps whatever it already has.
		guard !GameMode.isEnabled else { return }

		let loaded = SourcesViewModel.shared.sources
		let updatedIDs = AppUpdateChecker.shared.appsWithUpdates

		// Dictionary order is not stable, so the widget would reshuffle itself on
		// every publish without this.
		let repositories = loaded
			.sorted { lhs, rhs in
				let left = lhs.key.name ?? lhs.value.name ?? ""
				let right = rhs.key.name ?? rhs.value.name ?? ""
				return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
			}
			.prefix(WidgetRepoPayload.maxSources)

		var sources: [WidgetRepoPayload.Source] = []
		var iconURLs: [String: URL] = [:]

		for (altSource, repository) in repositories {
			let apps = repository.apps.prefix(WidgetRepoPayload.appsPerSource).map { app in
				if let iconURL = app.iconURL {
					iconURLs[app.currentUniqueId] = iconURL
				}
				return WidgetRepoPayload.App(
					id: app.currentUniqueId,
					name: app.currentName,
					bundleID: app.id ?? "",
					version: app.currentVersion ?? "",
					iconFile: nil,
					hasUpdate: updatedIDs.contains(app.currentUniqueId)
				)
			}

			sources.append(
				WidgetRepoPayload.Source(
					url: altSource.sourceURL?.absoluteString ?? repository.sourceURL?.absoluteString ?? "",
					name: repository.name ?? altSource.name ?? .localized("Repository"),
					apps: Array(apps)
				)
			)
		}

		sources = await _attachIcons(to: sources, iconURLs: iconURLs)

		let payload = WidgetRepoPayload(sources: sources, lastUpdated: Date())
		guard payload.store() else {
			Logger.misc.error("Repository widget payload could not be written: app group unavailable")
			return
		}

		WidgetRepoPayload.pruneIconCache(referenced: Set(sources.flatMap { $0.apps }.compactMap { $0.iconFile }))
		WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
	}

	// MARK: - Icons

	/// Fills `iconFile` for every app whose icon is (or can be) cached. Anything
	/// that fails simply stays nil — the widget shows its placeholder instead.
	private static func _attachIcons(
		to sources: [WidgetRepoPayload.Source],
		iconURLs: [String: URL]
	) async -> [WidgetRepoPayload.Source] {
		guard let folder = WidgetRepoPayload.iconCacheURL else { return sources }
		try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

		// Only fetch what is not on disk yet, and only up to the per-pass cap.
		var toFetch: [URL] = []
		for id in iconURLs.keys.sorted() where toFetch.count < _maxIconFetches {
			guard let url = iconURLs[id], let cached = WidgetRepoPayload.cachedIconURL(for: url) else { continue }
			if !_exists(cached) && !toFetch.contains(url) {
				toFetch.append(url)
			}
		}

		if !toFetch.isEmpty {
			await _fetch(toFetch, into: folder)
		}

		return sources.map { source in
			var updated = source
			updated.apps = source.apps.map { app in
				var app = app
				if let url = iconURLs[app.id],
				   let cached = WidgetRepoPayload.cachedIconURL(for: url),
				   _exists(cached) {
					app.iconFile = cached.lastPathComponent
				}
				return app
			}
			return updated
		}
	}

	private static func _exists(_ url: URL?) -> Bool {
		guard let url else { return false }
		return FileManager.default.fileExists(atPath: url.path)
	}

	private static func _fetch(_ urls: [URL], into folder: URL) async {
		let unique = Array(Set(urls))

		await withTaskGroup(of: Void.self) { group in
			var running = 0
			for url in unique {
				if running >= _iconFetchConcurrency {
					await group.next()
					running -= 1
				}
				running += 1
				group.addTask {
					await _download(url, into: folder)
				}
			}
		}
	}

	private static func _download(_ url: URL, into folder: URL) async {
		let destination = WidgetRepoPayload.cachedIconURL(for: url) ?? folder
		guard !_exists(destination) else { return }

		do {
			var request = URLRequest(url: url)
			request.timeoutInterval = 15
			let (data, response) = try await URLSession.shared.data(for: request)

			guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return }
			guard data.count <= _maxIconBytes, UIImage(data: data) != nil else { return }

			try data.write(to: destination, options: .atomic)
		} catch {
			// A missing icon is cosmetic; the widget has a placeholder.
			Logger.misc.debug("Widget icon fetch failed for \(url.absoluteString, privacy: .public)")
		}
	}
}
