import SwiftUI

@MainActor
final class DiscoveryViewModel: ObservableObject {
    @Published private(set) var apps: [DiscoveryApp] = []
    @Published private(set) var results: [DiscoveryApp] = []
    @Published private(set) var signals = DiscoverySignals()
    @Published private(set) var loading = false
    @Published var error: String?
    private let index = DiscoveryIndex()
    /// injected so a test can construct this view model with a fake.
    private let useCase: DiscoveryUseCase
    private var generation = 0
    private var currentQuery = ""

    init(useCase: DiscoveryUseCase) { self.useCase = useCase }

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
            signals = try await useCase.signals()
            if apps.isEmpty {
                apps = try await useCase.cachedApps()
                await index.replace(apps); await search(currentQuery)
            }
            guard let refreshed = try await useCase.refresh(force: force) else { return }
            apps = refreshed
            await index.replace(apps); await search(currentQuery)
            error = nil
        } catch is CancellationError {
            // Keep the last good catalog on cancellation.
        } catch { self.error = error.localizedDescription }
    }
    func versions(for bundleIdentifier: String) -> [DiscoveryApp] {
        let key = CatalogIdentity.bundleKey(bundleIdentifier) ?? bundleIdentifier
        return apps
            .filter { (CatalogIdentity.bundleKey($0.bundleIdentifier) ?? $0.bundleIdentifier) == key }
            .sorted { DiscoveryApp.isPreferred($0, over: $1) }
    }

    func search(_ query: String) async {
        currentQuery = query
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
        do { try useCase.download(app) }
        catch { self.error = error.localizedDescription; return }
        signals.downloads[app.id, default: 0] += 1
        await persistSignals()
    }
    private func persistSignals() async {
        do { try await useCase.saveSignals(signals) } catch { self.error = error.localizedDescription }
    }
}
