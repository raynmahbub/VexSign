import SwiftUI
import AltSourceKit

@MainActor
final class DiscoveryViewModel: ObservableObject {
    @Published private(set) var apps: [DiscoveryApp] = []
    @Published private(set) var results: [DiscoveryApp] = []
    @Published private(set) var signals = DiscoverySignals()
    @Published private(set) var loading = false
    @Published var error: String?
    private let index = DiscoveryIndex()
    /// injected so a test can construct this view model with a fake.
    private let downloads: PackageDownloading
    private var generation = 0

    init(downloads: PackageDownloading = DownloadManager.shared) {
        self.downloads = downloads
    }

    var categories: [CategoryItem] {
        Dictionary(grouping: results, by: \.category).map { CategoryItem(name: $0.key, apps: $0.value) }.sorted { $0.name < $1.name }
    }
    var collections: [CollectionItem] {
        [.init(id: "favorites", title: "Your Favorites", apps: results.filter { signals.favorites.contains($0.id) }),
         .init(id: "recent", title: "Recently Updated", apps: results.sorted { ($0.updated ?? .distantPast) > ($1.updated ?? .distantPast) })]
    }
    func load(force: Bool = false) async {
        guard !loading else { return }
        loading = true; defer { loading = false }
        do {
            signals = try await EcosystemDatabase.shared.read("discovery.signals", as: DiscoverySignals.self) ?? .init()
            if apps.isEmpty {
                apps = try await EcosystemDatabase.shared.read("discovery.apps", as: [DiscoveryApp].self) ?? []
                await index.replace(apps); await search("")
            }
            if !GameMode.isEnabled {
                // Reuse the existing parser/authentication/coalescing pipeline, including encrypted ESign.
                await SourcesViewModel.shared.fetchSources(Storage.shared.getSources(), refresh: force)
            }
            let loaded = SourcesViewModel.shared.sources
            guard !loaded.isEmpty else { return }
            var next: [DiscoveryApp] = []
            for (source, repository) in loaded {
                let sourceID = source.sourceURL?.absoluteString ?? source.identifier ?? ""
                for app in repository.apps {
                    guard let bundleID = app.id else { continue }
                    next.append(.init(id: sourceID + "#" + bundleID, source: sourceID, bundleIdentifier: bundleID,
                                      name: app.currentName, summary: app.currentDescription ?? "", developer: app.developer ?? "",
                                      category: app.category ?? "Other", version: app.currentVersion ?? "",
                                      icon: app.iconURL, download: app.currentDownloadUrl, updated: app.currentDate?.date,
                                      releases: app.versions?.filter { ($0.date?.date ?? .distantPast) > Date(timeIntervalSinceNow: -90 * 86_400) }.count ?? 0))
                }
            }
            apps = Array(Dictionary(next.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values)
            try await EcosystemDatabase.shared.write(apps, key: "discovery.apps")
            await index.replace(apps); await search("")
        } catch { self.error = error.localizedDescription }
    }
    func versions(for bundleIdentifier: String) -> [DiscoveryApp] {
        apps.filter { $0.bundleIdentifier == bundleIdentifier }
            .sorted { ($0.updated ?? .distantPast) > ($1.updated ?? .distantPast) }
    }

    func search(_ query: String) async {
        generation += 1; let token = generation
        let found = await index.search(query, signals: signals)
        guard token == generation, !Task.isCancelled else { return }
        results = found
    }
    func favorite(_ app: DiscoveryApp) async {
        if signals.favorites.contains(app.id) { signals.favorites.remove(app.id) } else { signals.favorites.insert(app.id) }
        await persistSignals()
    }
    func download(_ app: DiscoveryApp) async {
        guard let url = app.download, RepositoryValidator.webURL(url.absoluteString) != nil else { error = "Invalid download URL."; return }
        _ = downloads.startPackageDownload(from: url, appName: app.name, appDescription: app.summary, integrity: nil)
        signals.downloads[app.id, default: 0] += 1
        await persistSignals()
    }
    private func persistSignals() async {
        do { try await EcosystemDatabase.shared.write(signals, key: "discovery.signals") }
        catch { self.error = error.localizedDescription }
    }
}
