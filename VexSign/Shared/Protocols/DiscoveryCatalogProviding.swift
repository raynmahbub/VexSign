import Foundation

@MainActor
protocol DiscoveryCatalogProviding: AnyObject {
    func cachedApps() async throws -> [DiscoveryApp]
    func signals() async throws -> DiscoverySignals
    func refreshedApps(force: Bool) async throws -> [DiscoveryApp]?
    func saveApps(_ apps: [DiscoveryApp]) async throws
    func saveSignals(_ signals: DiscoverySignals) async throws
    func download(_ app: DiscoveryApp) throws
}
