import Foundation

@MainActor
final class DiscoveryUseCase {
    private let provider: DiscoveryCatalogProviding
    private let policy: SecurityPolicyValidating
    init(provider: DiscoveryCatalogProviding, policy: SecurityPolicyValidating) {
        self.provider = provider
        self.policy = policy
    }
    func cachedApps() async throws -> [DiscoveryApp] { try await provider.cachedApps() }
    func signals() async throws -> DiscoverySignals { try await provider.signals() }
    func refresh(force: Bool) async throws -> [DiscoveryApp]? {
        guard let apps = try await provider.refreshedApps(force: force) else { return nil }
        try Task.checkCancellation()
        let unique = Dictionary(apps.map { ($0.id, $0) }, uniquingKeysWith: {
            DiscoveryApp.isPreferred($0, over: $1) ? $0 : $1
        }).values.sorted { $0.id < $1.id }
        try await provider.saveApps(unique)
        return unique
    }
    func saveSignals(_ signals: DiscoverySignals) async throws { try await provider.saveSignals(signals) }
    func download(_ app: DiscoveryApp) throws {
        guard let url = app.download else { throw URLError(.badURL) }
        // Admit the intent before touching a provider or recording popularity.
        // The infrastructure adapter independently retains its transport gate.
        try policy.validatePackageDownloadURL(url)
        try provider.download(app)
    }
}
