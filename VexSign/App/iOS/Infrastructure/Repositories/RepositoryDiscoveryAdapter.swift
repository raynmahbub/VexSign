import Foundation
import AltSourceKit

@MainActor
final class RepositoryDiscoveryAdapter: DiscoveryCatalogProviding {
    private let catalog: SourceCatalogStore
    private let storage: Storage
    private let downloads: PackageDownloading
    private let security: SecurityPolicyValidating
    init(catalog: SourceCatalogStore, storage: Storage, downloads: PackageDownloading, security: SecurityPolicyValidating) {
        self.catalog = catalog; self.storage = storage; self.downloads = downloads; self.security = security
    }
    func cachedApps() async throws -> [DiscoveryApp] {
        try await EcosystemDatabase.shared.read("discovery.apps", as: [DiscoveryApp].self) ?? []
    }
    func signals() async throws -> DiscoverySignals {
        try await EcosystemDatabase.shared.read("discovery.signals", as: DiscoverySignals.self) ?? .init()
    }
    func saveApps(_ apps: [DiscoveryApp]) async throws { try await EcosystemDatabase.shared.write(apps, key: "discovery.apps") }
    func saveSignals(_ signals: DiscoverySignals) async throws { try await EcosystemDatabase.shared.write(signals, key: "discovery.signals") }
    func refreshedApps(force: Bool) async throws -> [DiscoveryApp]? {
        let configured = storage.getSources()
        if configured.isEmpty {
            catalog.evictDeletedSources(valid: [])
            return []
        }
        if !GameMode.isEnabled { await catalog.fetchSources(configured, refresh: force) }
        try Task.checkCancellation()
        guard !catalog.sources.isEmpty else { return nil }
        var apps: [DiscoveryApp] = []
        for (source, repository) in catalog.sources where !source.isDeleted {
            let rawSource = source.sourceURL?.absoluteString ?? source.identifier ?? ""
            let sourceID = CatalogIdentity.sourceKey(rawSource) ?? rawSource
            for app in repository.apps {
                guard let bundleID = app.id, let listingID = CatalogIdentity.appID(source: rawSource, bundleIdentifier: bundleID) else { continue }
                apps.append(.init(id: listingID, source: sourceID, bundleIdentifier: bundleID,
                    name: app.currentName, summary: app.currentDescription ?? "", developer: app.developer ?? "",
                    category: app.category ?? "Other", version: app.currentVersion ?? "", icon: app.iconURL,
                    download: app.currentDownloadUrl, updated: app.currentDate?.date,
                    releases: app.versions?.filter { ($0.date?.date ?? .distantPast) > Date(timeIntervalSinceNow: -90 * 86_400) }.count ?? 0,
                    downloadByteCount: app.downloadIntegrityExpectation.byteCount))
            }
        }
        return apps
    }
    func download(_ app: DiscoveryApp) throws {
        guard let url = app.download else { throw URLError(.badURL) }
        try security.validatePackageDownloadURL(url)
        _ = downloads.startPackageDownload(from: url, appName: app.name, appDescription: app.summary,
            integrity: .init(byteCount: app.downloadByteCount))
    }
}
