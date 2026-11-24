import Foundation
import XCTest
@testable import VexSign

private final class RecordingDiscoveryDownloader: PackageDownloading {
    var requests: [Download] = []

    func startPackageDownload(
        from url: URL, appName: String?, appDescription: String?,
        integrity: DownloadIntegrity.Expectation?
    ) -> Download {
        let download = Download(id: UUID().uuidString, url: url, appName: appName,
            appDescription: appDescription, integrity: integrity)
        requests.append(download)
        return download
    }
}

@MainActor
final class RepositoryDiscoveryAdapterTests: XCTestCase {
    private func listing(byteCount: Int64? = nil, url: String = "https://example.com/app.ipa") -> DiscoveryApp {
        DiscoveryApp(id: "https://example.com/source.json#com.example.app",
            source: "https://example.com/source.json", bundleIdentifier: "com.example.app",
            name: "Example", summary: "A source app", developer: "Example", category: "Utilities",
            version: "1.0", icon: nil, download: URL(string: url), updated: nil, releases: 1,
            downloadByteCount: byteCount)
    }

    private func adapter(downloads: RecordingDiscoveryDownloader) -> RepositoryDiscoveryAdapter {
        RepositoryDiscoveryAdapter(
            catalog: SourceCatalogStore(fetcher: { _, _ in .failure(URLError(.notConnectedToInternet)) },
                retainSnapshots: { _ in }, usesBackgroundTask: false),
            storage: Storage(inMemory: true), downloads: downloads, security: SecurityPolicyGateway())
    }

    func testDiscoveryForwardsTheSourcesSelectedDownloadSize() throws {
        let downloads = RecordingDiscoveryDownloader()
        let app = listing(byteCount: 123)
        try adapter(downloads: downloads).download(app)

        let request = try XCTUnwrap(downloads.requests.first)
        XCTAssertEqual(downloads.requests.count, 1)
        XCTAssertEqual(request.url, app.download)
        XCTAssertEqual(request.fileName, app.name)
        XCTAssertEqual(request.appDescription, app.summary)
        XCTAssertEqual(request.integrity?.byteCount, 123)
        XCTAssertNil(request.integrity?.sha256)
    }

    func testAnOldListingWithoutSizeRemainsUnverifiedAndDownloadable() throws {
        let downloads = RecordingDiscoveryDownloader()
        try adapter(downloads: downloads).download(listing())
        XCTAssertEqual(downloads.requests.count, 1)
        XCTAssertEqual(downloads.requests.first?.integrity?.isEmpty, true)
    }

    func testInvalidURLIsStillRejectedBeforeDownloaderAdmission() {
        let downloads = RecordingDiscoveryDownloader()
        XCTAssertThrowsError(try adapter(downloads: downloads).download(listing(byteCount: 123,
            url: "ftp://example.com/app.ipa")))
        XCTAssertTrue(downloads.requests.isEmpty)
    }

    func testSizeSurvivesCatalogPersistenceAndOlderCatalogsStillDecode() throws {
        let app = listing(byteCount: 123)
        let encoded = try JSONEncoder().encode(app)
        let restored = try JSONDecoder().decode(DiscoveryApp.self, from: encoded)
        XCTAssertEqual(restored.download, app.download)
        XCTAssertEqual(restored.downloadByteCount, 123)

        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "downloadByteCount")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        let decodedLegacy = try JSONDecoder().decode(DiscoveryApp.self, from: legacyData)
        XCTAssertNil(decodedLegacy.downloadByteCount)
        XCTAssertEqual(decodedLegacy.download, app.download)
    }

    func testRefreshCarriesTheSameSizeIntoTheActualDownloadAdapter() async throws {
        let previousGameMode = UserDefaults.standard.object(forKey: GameMode.enabledKey)
        UserDefaults.standard.set(false, forKey: GameMode.enabledKey)
        defer {
            if let previousGameMode { UserDefaults.standard.set(previousGameMode, forKey: GameMode.enabledKey) }
            else { UserDefaults.standard.removeObject(forKey: GameMode.enabledKey) }
        }
        let payload = Data("""
        {"name":"Fixture","apps":[{"name":"Example","bundleIdentifier":"com.example.app",
        "iconURL":"https://example.com/icon.png","downloadURL":"https://example.com/latest.ipa","size":999,
        "versions":[{"version":"1.0","downloadURL":"https://example.com/selected.ipa","size":123}]}]}
        """.utf8)
        let storage = Storage(inMemory: true)
        let sourceID = "test.discovery.integrity.\(UUID().uuidString)"
        let source = AltSource(context: storage.context)
        source.identifier = sourceID
        source.date = Date()
        source.sourceURL = URL(string: "https://example.com/\(sourceID).json")
        try storage.context.save()
        defer {
            RepositorySnapshotCache.remove(identifier: sourceID)
            SourcePreferences.removeAllData(for: sourceID)
        }
        let catalog = SourceCatalogStore(fetcher: { _, _ in .success(payload) },
            retainSnapshots: { _ in }, usesBackgroundTask: false)
        let downloads = RecordingDiscoveryDownloader()
        let adapter = RepositoryDiscoveryAdapter(catalog: catalog, storage: storage,
            downloads: downloads, security: SecurityPolicyGateway())

        let apps = try await adapter.refreshedApps(force: true)
        let app = try XCTUnwrap(apps?.first)
        XCTAssertEqual(app.download?.lastPathComponent, "selected.ipa")
        XCTAssertEqual(app.downloadByteCount, 123)
        try adapter.download(app)
        XCTAssertEqual(downloads.requests.first?.url, app.download)
        XCTAssertEqual(downloads.requests.first?.integrity?.byteCount, 123)
    }
}
