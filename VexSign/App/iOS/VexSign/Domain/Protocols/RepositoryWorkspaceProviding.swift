import Foundation

struct RepositoryCatalogState<Catalog: Sendable>: Sendable {
    let catalogs: [RepositoryRecord: Catalog]
    let isFinished: Bool
    let staleSourceIDs: Set<String>
}

@MainActor
protocol RepositoryCatalogProviding<Catalog>: AnyObject {
    associatedtype Catalog: Sendable
    func catalogState() -> RepositoryCatalogState<Catalog>
    func catalogChanges() -> AsyncStream<RepositoryCatalogState<Catalog>>
    func refreshCatalogs(_ sources: [RepositoryRecord], force: Bool, batchSize: Int, configuredSources: [RepositoryRecord]?) async throws
    func retainCatalogs(for sources: [RepositoryRecord]) throws
    func resetLoadingState()
}

struct RepositoryConfiguration: Sendable {
    let url: URL
    let name: String?
    let identifier: String
    let iconURL: URL?
}

@MainActor
protocol RepositoryManagementProviding<Catalog>: AnyObject {
    associatedtype Catalog: Sendable
    func addRepository(_ configuration: RepositoryConfiguration, completion: @escaping @MainActor (Error?) -> Void)
    func addRepositories(_ configurations: [RepositoryConfiguration], completion: @escaping @MainActor (Error?) -> Void)
    func addRepository(address: String, completion: @escaping @MainActor (Result<String, Error>) -> Void)
    func removeRepositories(ids: [String], offeringUndo: Bool) throws
    func fetchRepositories(from urls: [URL]) async -> [(URL, Catalog)]
    func fetchDirectory() async throws -> [URL]
}
