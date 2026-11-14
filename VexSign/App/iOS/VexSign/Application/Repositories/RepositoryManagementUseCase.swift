import Foundation

@MainActor
final class RepositoryManagementUseCase<Catalog: Sendable> {
    private let provider: any RepositoryManagementProviding<Catalog>
    private let policy: SecurityPolicyValidating
    init(provider: any RepositoryManagementProviding<Catalog>, policy: SecurityPolicyValidating) {
        self.provider = provider
        self.policy = policy
    }

    func add(_ configuration: RepositoryConfiguration, completion: @escaping @MainActor (Error?) -> Void) {
        do { try policy.validateRepositoryURL(configuration.url) }
        catch { completion(error); return }
        provider.addRepository(configuration, completion: completion)
    }

    func add(_ configurations: [RepositoryConfiguration], completion: @escaping @MainActor (Error?) -> Void) {
        do { for item in configurations { try policy.validateRepositoryURL(item.url) } }
        catch { completion(error); return }
        provider.addRepositories(configurations, completion: completion)
    }

    func add(address: String, completion: @escaping @MainActor (Result<String, Error>) -> Void) {
        // Address normalization, duplicate/provenance checks and fetching remain
        // one transaction in the existing repository importer.
        provider.addRepository(address: address, completion: completion)
    }

    func remove(_ sources: [RepositoryRecord], offeringUndo: Bool = true) throws {
        try provider.removeRepositories(ids: sources.map(\.id), offeringUndo: offeringUndo)
    }

    func fetch(from urls: [URL]) async -> [(URL, Catalog)] {
        // The provider enforces the same transport policy per source and can
        // return a partial catalog for offline or unavailable repositories.
        await provider.fetchRepositories(from: urls)
    }
    func directory() async throws -> [URL] {
        let urls = try await provider.fetchDirectory()
        for url in urls { try policy.validateRepositoryURL(url) }
        return urls
    }
}
