//
//  SourcesViewModel.swift
//  VexSign
//
//  Created by VexSign Contributors on 30.04.2025.
//

import Foundation
import AltSourceKit
import SwiftUI
import NimbleJSON
import OSLog
import NimbleExtensions

// MARK: - Class
final class SourcesViewModel: ObservableObject {
	static let shared = SourcesViewModel()

	private let fetcher: SourceFeedLoader.Fetcher
	private let retainSnapshots: (Set<String>) -> Void
	private let usesBackgroundTask: Bool

	init(
		fetcher: SourceFeedLoader.Fetcher? = nil,
		retainSnapshots: @escaping (Set<String>) -> Void = RepositorySnapshotCache.retainOnly,
		usesBackgroundTask: Bool? = nil
	) {
		self.fetcher = fetcher ?? Self._fetcher()
		self.retainSnapshots = retainSnapshots
		self.usesBackgroundTask = usesBackgroundTask ?? (fetcher == nil)
	}

	/// `true` when no load is in progress (idle).
	@Published var isFinished = true
	@Published var sources: [AltSource: ASRepository] = [:]

	/// Sources currently shown from the offline snapshot cache rather than a
	/// fresh load (offline / failing). Browsed data stays available and is
	/// clearly marked stale.
	@Published private(set) var staleSourceIDs: Set<String> = []

	/// The single in-flight load. All loads are serialized through this.
	private var currentFetchTask: Task<Void, Never>?
	/// Monotonic token identifying the active load (Task isn't Equatable).
	private var fetchGeneration = 0
	/// Source URLs of the last completed load; skips re-fetching an identical set.
	private var lastLoadedKey: Set<String>?
	private var lastLoadedAt: Date?
	private var backgroundTaskManager: BackgroundTaskManager?

	private func key(for sources: [AltSource]) -> Set<String> {
		Set(sources.compactMap { $0.sourceURL?.absoluteString })
	}

	/// Decodes cached snapshots on a background executor: file I/O plus JSON for every source.
	private static func _cachedRepositories(for identifiers: Set<String>) async -> [String: ASRepository] {
		guard !identifiers.isEmpty else { return [:] }

		return await Task.detached(priority: .userInitiated) {
			var decoded: [String: ASRepository] = [:]
			for identifier in identifiers {
				if let cached = RepositorySnapshotCache.load(identifier: identifier) {
					decoded[identifier] = cached.repository
				}
			}
			return decoded
		}.value
	}

	/// The production fetcher: `NBFetchService` behind the async closure the loader takes.
	///
	/// The service is constructed inside the closure rather than passed in: the
	/// loader's fetcher is `@Sendable`, `NBFetchService` is a class that is not
	/// `Sendable`, and it holds no per-instance state worth keeping anyway.
	private static func _fetcher() -> SourceFeedLoader.Fetcher {
		{ url, headers in
			let service = NBFetchService()
			return await withCheckedContinuation { continuation in
				service.fetchRaw(from: url, headers: headers) { result in
					continuation.resume(returning: result)
				}
			}
		}
	}

	/// Stable identifier for a source record (falls back to its URL).
	private static func _id(for source: AltSource, fallbackURL: URL? = nil) -> String {
		source.identifier ?? fallbackURL?.absoluteString ?? source.sourceURL?.absoluteString ?? source.objectID.uriRepresentation().absoluteString
	}

	/// Reset the loading state - useful when app returns from background
	@MainActor
	func resetLoadingState() {
		currentFetchTask?.cancel()
		currentFetchTask = nil
		fetchGeneration += 1
		isFinished = true
		lastLoadedKey = nil
		backgroundTaskManager?.stop()
		backgroundTaskManager = nil
	}

	/// True when the source is currently shown from the offline snapshot
	/// cache rather than a fresh load.
	func isStale(_ source: AltSource) -> Bool {
		staleSourceIDs.contains(Self._id(for: source))
	}

	/// Drops every cached entry whose Core Data object no longer exists
	/// (e.g. the repository was deleted while a refresh was running). Without
	/// this, iterating the dictionary after a deletion touches a faulted
	/// managed object and can crash the App Store tab.
	@MainActor
	func evictDeletedSources(valid sources: [AltSource]) {
		let validSet = Set(sources)
		let doomed = self.sources.keys.filter { $0.isDeleted || !validSet.contains($0) }
		guard !doomed.isEmpty else { return }
		for source in doomed {
			self.sources.removeValue(forKey: source)
		}
		let doomedIDs = Set(doomed.map { Self._id(for: $0) })
		staleSourceIDs.subtract(doomedIDs)
		for source in doomed {
			let id = Self._id(for: source)
			SourcePreferences.removeAllData(for: id, automaticUpdateAlias: source.sourceURL?.absoluteString)
			RepositorySnapshotCache.remove(identifier: id)
		}
	}

	/// Loads every source's repository. Concurrent calls are serialized and coalesced.
	@MainActor
	func fetchSources(_ sources: FetchedResults<AltSource>, refresh: Bool = false, batchSize: Int = 4) async {
		await fetchSources(Array(sources), refresh: refresh, batchSize: batchSize)
	}

	/// Array-based overload for callers without a `FetchedResults` (Update All, background automation).
	@MainActor
	func fetchSources(_ sourcesArray: [AltSource], refresh: Bool = false, batchSize: Int = 4, configuredSources: [AltSource]? = nil) async {
		let configured = configuredSources ?? sourcesArray
		let targets = Set(sourcesArray)
		let isFullRefresh = targets == Set(configured)
		let newKey = key(for: configured)

		// Coalesce: wait out any in-flight load. The task self-clears in its own
		// defer so awaiters exit instead of busy-spinning the main actor (0x8BADF00D).
		while let running = currentFetchTask {
			await running.value
		}

		// Same source set already loaded — skip (pull-to-refresh bypasses this).
		if isFullRefresh, !refresh, newKey == lastLoadedKey, let lastLoadedAt, Date().timeIntervalSince(lastLoadedAt) < RepositorySyncEngine.refreshInterval {
			return
		}

		fetchGeneration += 1
		let generation = fetchGeneration
		let task = Task {
			defer {
				// Self-clear exactly once, unless a newer load already replaced us.
				if generation == self.fetchGeneration {
					self.currentFetchTask = nil
				}
			}
			await self._performFetch(configured, targets: targets, key: newKey, batchSize: max(1, batchSize), generation: generation, isFullRefresh: isFullRefresh)
		}
		currentFetchTask = task
		await task.value
	}

	@MainActor
	private func _performFetch(_ sourcesArray: [AltSource], targets: Set<AltSource>, key: Set<String>, batchSize: Int, generation: Int, isFullRefresh: Bool) async {
		isFinished = false

		if usesBackgroundTask && backgroundTaskManager == nil {
			backgroundTaskManager = BackgroundTaskManager(
				taskName: "SourcesViewModel",
				expirationTitle: "Loading repositories",
				expirationBody: "Repository loading will continue when you reopen the app"
			)
			backgroundTaskManager?.start()
		}

		defer {
			if generation == fetchGeneration {
				if isFullRefresh { lastLoadedKey = key }
				isFinished = true
				backgroundTaskManager?.stop()
				backgroundTaskManager = nil
			}
		}

		// Reconcile the in-memory catalog with the persisted source set before any
		// awaits. Empty and failed refreshes must not leave deleted repositories
		// available to update matching or automatic maintenance.
		evictDeletedSources(valid: sourcesArray)
		let configuredIDs = Set(sourcesArray.map { Self._id(for: $0) })
		staleSourceIDs.formIntersection(configuredIDs)

		// Read CoreData (AltSource) fields on the main actor — it's not thread-safe.
		struct FetchItem {
			let source: AltSource
			let identifier: String
			let url: URL
			let headers: [String: String]
			let isPremium: Bool
		}

		var items: [FetchItem] = []
		var transportBlocked: [(source: AltSource, identifier: String)] = []
		for source in sourcesArray {
			guard !source.isDeleted else { continue }
			guard let url = source.sourceURL else {
				Logger.misc.error("Source has no URL: \(source.name ?? "Unknown", privacy: .public)")
				continue
			}
			// Transport policy: an insecure HTTP repository is not refreshed
			// (and its traffic not sent) unless the user opted in. The catalog
			// — if cached — keeps serving as clearly-marked stale data.
			do {
				try SourceURLPolicy.validate(url)
			} catch {
				let id = Self._id(for: source, fallbackURL: url)
				if targets.contains(source) { SourcePreferences.recordFetch(id: id, error: error.localizedDescription) }
				Logger.security.warning("Skipping refresh of insecure repository: \(url.absoluteString, privacy: .public)")
				transportBlocked.append((source, id))
				continue
			}
			let isGitHubReleaseSource = GitHubReleaseSource.isGitHubRepositoryURL(url)
			var headers = isGitHubReleaseSource ? [:] : VexSignAPI.authHeaders(for: url)
			#if canImport(AltSourceKit)
			if !isGitHubReleaseSource, !EsignSourceKey.customApiKey.isEmpty, headers["X-API-Key"] == nil {
				headers["X-API-Key"] = EsignSourceKey.customApiKey
			}
			#endif
			items.append(FetchItem(
				source: source,
				identifier: Self._id(for: source, fallbackURL: url),
				url: isGitHubReleaseSource ? url : VexSignAPI.catalogURL(for: url),
				headers: headers,
				isPremium: !isGitHubReleaseSource && VexSignAPI.isPremiumSource(url)
			))
		}

		Logger.misc.info("fetchSources START: \(items.count, privacy: .public) sources")

		// Offline prefill: any source with no in-memory catalog gets its last
		// known-good snapshot immediately, so the store is browsable while the
		// refresh runs (and entirely offline after a cold launch).
		var working = self.sources.filter { sourcesArray.contains($0.key) }
		// Publish even an empty catalog; retaining the previous dictionary here
		// lets removed sources leak into callers that read cached values directly.
		self.sources = working

		// Reading and decoding those snapshots is file I/O plus JSON per source, so it happens off
		// the main actor too — only the models come back here to be published.
		let snapshots = await Self._cachedRepositories(
			for: Set(items.map(\.identifier) + transportBlocked.map(\.identifier))
		)

		guard generation == fetchGeneration, !Task.isCancelled else { return }
		working = working.filter { !$0.key.isDeleted }
		for item in items where !item.source.isDeleted && working[item.source] == nil {
			if var cached = snapshots[item.identifier] {
				cached.sourceURL = item.source.sourceURL
				working[item.source] = cached
				staleSourceIDs.insert(item.identifier)
			}
		}
		// Sources blocked by the transport policy keep their cached catalog
		// too — browsing works, refreshes simply don't run for them.
		for blocked in transportBlocked where !blocked.source.isDeleted && working[blocked.source] == nil {
			if var cached = snapshots[blocked.identifier] {
				cached.sourceURL = blocked.source.sourceURL
				working[blocked.source] = cached
			}
			if working[blocked.source] != nil {
				staleSourceIDs.insert(blocked.identifier)
			}
		}
		self.sources = working

		// A rate-limited source is skipped entirely this round: hammering it
		// again only extends the window.
		let selectedItems = items.filter { targets.contains($0.source) && !$0.source.isDeleted }
		let rateLimitedIDs = Set(selectedItems.filter { SourcePreferences.health(for: $0.identifier).isRateLimited }.map { $0.identifier })
		let fetchable = selectedItems.filter { !rateLimitedIDs.contains($0.identifier) }
		for item in selectedItems where rateLimitedIDs.contains(item.identifier) {
			Logger.misc.warning("Source rate-limited, skipping this refresh: \(item.identifier, privacy: .public)")
		}

		var successes = 0

		// Fetch *and* decode happen in the loader, which has no isolation, so neither runs on the
		// main actor. The task group only carries `SourceFeedResult` back.
		let loader = SourceFeedLoader(fetcher: fetcher)

		for startIndex in stride(from: 0, to: fetchable.count, by: batchSize) {
			let endIndex = min(startIndex + batchSize, fetchable.count)
			let batch = Array(fetchable[startIndex..<endIndex])

			// Child tasks touch only Sendable values, never the NSManagedObject.
			let loaded: [SourceFeedResult] = await withTaskGroup(of: SourceFeedResult.self) { group in
				for item in batch {
					let url = item.url
					let headers = item.headers
					let identifier = item.identifier

					group.addTask {
						await loader.load(url: url, headers: headers, identifier: identifier)
					}
				}

				var collected: [SourceFeedResult] = []
				for await result in group {
					collected.append(result)
				}
				return collected
			}

			guard generation == fetchGeneration, !Task.isCancelled else { return }
			// A source may have been deleted while the network request was in flight.
			working = working.filter { !$0.key.isDeleted }

			// Publishing happens here, on the main actor, from finished values only.
			let signpost = SourceFeedSignposts.publish.beginInterval(
				"publish",
				id: SourceFeedSignposts.publish.makeSignpostID()
			)
			defer { SourceFeedSignposts.publish.endInterval("publish", signpost) }

			let outcomes = Dictionary(
				loaded.map { ($0.identifier, $0.outcome) },
				uniquingKeysWith: { _, latest in latest }
			)

			for item in batch {
				guard !item.source.isDeleted, let outcome = outcomes[item.identifier] else { continue }

				switch outcome {
				case let .decoded(repository, payload):
					successes += 1
					var decoded = repository
					// Repositories are published as bare JSON and carry no
					// self-reference, so record where this one came from.
					decoded.sourceURL = item.source.sourceURL
					working[item.source] = decoded
					staleSourceIDs.remove(item.identifier)
					SourcePreferences.recordFetch(id: item.identifier, error: nil)
					RepositorySnapshotCache.store(
						identifier: item.identifier,
						sourceURL: item.source.sourceURL,
						payload: payload
					)

				case .invalid:
					// Invalid repository JSON: keep the last-known-good entry
					// (already in `working`) and record the real reason.
					SourcePreferences.recordFetch(
						id: item.identifier,
						error: .localized("Invalid repository data"),
						rateLimited: false
					)
					if working[item.source] != nil {
						staleSourceIDs.insert(item.identifier)
					}

				case let .failed(message, rateLimited):
					// Offline / server error / rate limited. The real message
					// goes into the health record; the catalog (if any) stays
					// as clearly-marked stale data.
					SourcePreferences.recordFetch(
						id: item.identifier,
						error: message,
						rateLimited: rateLimited
					)
					if working[item.source] != nil {
						staleSourceIDs.insert(item.identifier)
					}
				}
			}

			// Publish progress (grows, never empties).
			self.sources = working
		}

		// A rate-limited source that still has a catalog keeps it, marked stale.
		for item in selectedItems where rateLimitedIDs.contains(item.identifier) && working[item.source] != nil {
			staleSourceIDs.insert(item.identifier)
		}

		if isFullRefresh && successes == items.count && transportBlocked.isEmpty && rateLimitedIDs.isEmpty {
			lastLoadedAt = Date()
		} else {
			lastLoadedAt = nil
		}

		// Snapshot retention follows every configured source (including any
		// skipped by the transport policy or rate limit), not just the fetched
		// ones, so a skipped source keeps its last-known-good catalog.
		let allSourceIDs = Set(sourcesArray.filter { !$0.isDeleted }.map { Self._id(for: $0) })
		retainSnapshots(allSourceIDs)
		Logger.misc.info("fetchSources DONE: \(working.count, privacy: .public)/\(items.count, privacy: .public) loaded")
	}
}
