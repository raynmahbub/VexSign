import Foundation
import Combine
import AltSourceKit
import NimbleExtensions

@MainActor
final class RepositoryWorkspaceAdapter: RepositoryCatalogProviding, RepositoryManagementProviding {
    typealias Catalog = ASRepository
    private let catalog: SourceCatalogStore
    private let repository: CoreDataWorkspaceRepository
    private var storage: Storage { repository.storage }

    init(catalog: SourceCatalogStore, repository: CoreDataWorkspaceRepository) {
        self.catalog = catalog
        self.repository = repository
    }

    func catalogState() -> RepositoryCatalogState<ASRepository> {
        let values = catalog.sources.filter { !$0.key.isDeleted }.map { (repository.repositoryRecord($0.key), $0.value) }
        return RepositoryCatalogState(catalogs: Dictionary(values, uniquingKeysWith: { first, _ in first }),
                                      isFinished: catalog.isFinished, staleSourceIDs: catalog.staleSourceIDs)
    }

    func catalogChanges() -> AsyncStream<RepositoryCatalogState<ASRepository>> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuation.yield(catalogState())
            let subscription = Publishers.CombineLatest3(catalog.$sources, catalog.$isFinished, catalog.$staleSourceIDs)
                .sink { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        continuation.yield(self.catalogState())
                    }
                }
            let observation = StreamObservationCancellation(subscription)
            continuation.onTermination = { _ in observation.cancel() }
        }
    }

    func refreshCatalogs(_ sources: [RepositoryRecord], force: Bool, batchSize: Int, configuredSources: [RepositoryRecord]?) async throws {
        let rows = try sources.map { try storage.managedRepository(id: $0.id) }
        let configured = try configuredSources?.map { try storage.managedRepository(id: $0.id) }
        await catalog.fetchSources(rows, refresh: force, batchSize: batchSize, configuredSources: configured)
    }
    func retainCatalogs(for sources: [RepositoryRecord]) throws {
        catalog.evictDeletedSources(valid: try sources.map { try storage.managedRepository(id: $0.id) })
    }
    func resetLoadingState() { catalog.resetLoadingState() }

    func addRepository(_ item: RepositoryConfiguration, completion: @escaping @MainActor (Error?) -> Void) {
        storage.addSource(item.url, name: item.name, identifier: item.identifier, iconURL: item.iconURL, completion: completion)
    }
    func addRepositories(_ items: [RepositoryConfiguration], completion: @escaping @MainActor (Error?) -> Void) {
        var firstError: Error?
        var addedAny = false
        for item in items {
            let existed = storage.sourceExists(item.identifier)
            storage.addSource(item.url, name: item.name, identifier: item.identifier, iconURL: item.iconURL, deferSave: true) {
                if let error = $0 { if firstError == nil { firstError = error } }
                else if !existed { addedAny = true }
            }
        }
        do {
            try storage.context.save()
            if addedAny {
                Task { await AnalyticsStore.shared.record(.repositoriesAdded) }
                Haptics.lightImpact()
            }
        }
        catch { if firstError == nil { firstError = error } }
        completion(firstError)
    }
    func addRepository(address: String, completion: @escaping @MainActor (Result<String, Error>) -> Void) {
        RepositoryCatalogService.addSource(address, showAlerts: false) { result in
            Task { @MainActor in completion(result) }
        }
    }
    func removeRepositories(ids: [String], offeringUndo: Bool) throws {
        let rows = try ids.map { try storage.managedRepository(id: $0) }
        if offeringUndo { SourceRemoval.delete(rows) }
        else { for row in rows { storage.deleteSource(for: row) } }
    }
    func fetchRepositories(from urls: [URL]) async -> [(URL, ASRepository)] {
        await RepositoryCatalogService.fetchRepositories(from: urls)
    }
    func fetchDirectory() async throws -> [URL] {
        try await RepositoryDirectoryClient.fetch()
    }
}
