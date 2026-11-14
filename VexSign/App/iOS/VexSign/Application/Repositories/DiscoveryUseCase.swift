import Foundation

@MainActor
final class DiscoveryUseCase {
    private let provider: DiscoveryCatalogProviding
    init(provider: DiscoveryCatalogProviding) { self.provider = provider }
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
    func download(_ app: DiscoveryApp) throws { try provider.download(app) }
}
