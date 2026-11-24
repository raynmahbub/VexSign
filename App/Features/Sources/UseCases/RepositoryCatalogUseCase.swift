import Foundation

/// Keeps coalescing, offline snapshots, auth and decoding in the existing catalog
/// owner; the UI receives values and never resolves managed repository objects.
@MainActor
final class RepositoryCatalogUseCase<Catalog: Sendable> {
    private let provider: any RepositoryCatalogProviding<Catalog>
    init(provider: any RepositoryCatalogProviding<Catalog>) { self.provider = provider }
    func state() -> RepositoryCatalogState<Catalog> { provider.catalogState() }
    func changes() -> AsyncStream<RepositoryCatalogState<Catalog>> { provider.catalogChanges() }
    func refresh(_ sources: [RepositoryRecord], force: Bool = false, batchSize: Int = 4, configured: [RepositoryRecord]? = nil) async throws {
        try await provider.refreshCatalogs(sources, force: force, batchSize: max(1, batchSize), configuredSources: configured)
    }
    func retainConfiguredSources(_ sources: [RepositoryRecord]) throws { try provider.retainCatalogs(for: sources) }
    func resetLoadingState() { provider.resetLoadingState() }
}
