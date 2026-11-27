import XCTest
@testable import VexSign

/// Deterministic coverage for the versioned catalog pipeline. Every fixture is
/// built in memory: these tests assert parsing, validation, persistence and
/// decision logic, not that a live repository exists or is reachable.
final class CatalogPipelineTests: XCTestCase {
    private let sourceOne = "https://catalog.example.test/one.json"
    private let sourceTwo = "https://catalog.example.test/two.json"

    private func feed(
        name: String = "Example Source",
        bundle: String = "com.example.app",
        versions: String,
        extra: String = ""
    ) -> Data {
        Data("""
        {"name":"\(name)","schemaVersion":2,"apps":[{"name":"Example App","bundleIdentifier":"\(bundle)",
        "developerName":"Example Dev","iconURL":"https://cdn.example.test/icon.png",
        "localizedDescription":"A test application.",\(extra)
        "versions":[\(versions)]}]}
        """.utf8)
    }

    private func snapshot(_ data: Data, url: String) throws -> CatalogSnapshot {
        try CatalogFeedParser.parse(data, sourceID: CatalogIdentity.sourceKey(url) ?? url,
                                    sourceURL: url, format: .altStore)
    }

    // MARK: Parsing

    func testParserSortsReleaseHistoryAndPreservesAttributionAndUnknownFields() throws {
        let feedData = feed(versions: """
        {"version":"1.0","downloadURL":"https://cdn.example.test/v1.ipa","size":100},
        {"version":"2.0","downloadURL":"https://cdn.example.test/v2.ipa","size":200,"sha256":"ABCDEF"}
        """, extra: "\"upstreamTag\":\"kept\",")
        let parsed = try snapshot(feedData, url: sourceOne)

        XCTAssertEqual(parsed.schemaVersion, 2)
        XCTAssertEqual(parsed.apps.count, 1)
        XCTAssertEqual(parsed.apps[0].releases.map(\.version), ["2.0", "1.0"])
        XCTAssertEqual(parsed.apps[0].currentDownloadURL, "https://cdn.example.test/v2.ipa")
        XCTAssertEqual(parsed.apps[0].latest?.sha256, "abcdef")
        XCTAssertEqual(parsed.apps[0].sourceURL, sourceOne)
        XCTAssertEqual(parsed.apps[0].extra["upstreamTag"], .string("kept"))
        XCTAssertEqual(parsed.sha256.count, 64)
    }

    func testParserRejectsUnsupportedSchemaEncryptedFeedAndUnsafeURLs() throws {
        XCTAssertThrowsError(try snapshot(Data("{\"schemaVersion\":9,\"apps\":[]}".utf8), url: sourceOne)) { error in
            guard case CatalogParseError.unsupportedSchema(9) = error else { return XCTFail("expected schema refusal: \(error)") }
        }
        let encrypted = feed(versions: "{\"version\":\"1.0\",\"downloadURL\":\"https://cdn.example.test/v1.ipa\"}")
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        XCTAssertNotNil(encrypted)

        var encryptedJSON = feed(versions: "{\"version\":\"1.0\",\"downloadURL\":\"https://cdn.example.test/v1.ipa\"}")
        guard let text = String(data: encryptedJSON, encoding: .utf8) else { return XCTFail("fixture") }
        encryptedJSON = Data(text.replacingOccurrences(of: "{\"name\"", with: "{\"encrypted\":true,\"name\"").utf8)
        XCTAssertThrowsError(try snapshot(encryptedJSON, url: sourceOne))

        let unsafe = feed(versions: "{\"version\":\"1.0\",\"downloadURL\":\"file:///etc/passwd\"}")
        XCTAssertThrowsError(try snapshot(unsafe, url: sourceOne)) { error in
            guard case CatalogParseError.invalid = error else { return XCTFail("expected invalid feed: \(error)") }
        }
    }

    func testParserRejectsAmbiguousDuplicateBundleIdentifiers() throws {
        let first = feed(versions: "{\"version\":\"1.0\",\"downloadURL\":\"https://cdn.example.test/v1.ipa\"}")
        guard let text = String(data: first, encoding: .utf8) else { return XCTFail("fixture") }
        let duplicated = Data(text.replacingOccurrences(
            of: "\"}]}]}", with: "\"}]},{\"name\":\"Other\",\"bundleIdentifier\":\"com.example.app\",\"downloadURL\":\"https://cdn.example.test/v2.ipa\",\"version\":\"2.0\"}]}"
        ).utf8)
        XCTAssertThrowsError(try snapshot(duplicated, url: sourceOne))
    }

    func testESignWrappedFeedIsSupportedButCustomSchemaIsStrict() throws {
        let wrapped = Data("""
        {"name":"ESign Source","schemaVersion":1,"data":{"apps":[{"name":"App","bundleIdentifier":"com.example.app",
        "downloadURL":"https://cdn.example.test/app.ipa","version":"1.0"}]}}
        """.utf8)
        let parsed = try CatalogFeedParser.parseESign(wrapped, sourceID: "esign", sourceURL: sourceTwo)
        XCTAssertEqual(parsed.apps.first?.currentVersion, "1.0")
        XCTAssertThrowsError(try CatalogFeedParser.parse(
            Data("{\"name\":\"X\",\"schemaVersion\":2,\"apps\":[]}".utf8),
            sourceID: "custom", sourceURL: sourceOne, format: .custom
        ))
    }

    // MARK: Persistence, source metadata and health

    func testLastKnownGoodSnapshotSurvivesFailedRefreshAndRemovalDropsIt() async throws {
        let database = EcosystemDatabase()
        let persistence = CatalogPersistence(database: database)
        let registry = CatalogSourceRegistry(persistence: persistence)
        let source = try await registry.add(url: URL(string: sourceOne)!, name: "Example", format: .altStore)
        let validated = try snapshot(
            feed(versions: "{\"version\":\"1.0\",\"downloadURL\":\"https://cdn.example.test/v1.ipa\"}"),
            url: sourceOne
        )

        _ = try await registry.recordRefresh(id: source.id, outcome: .verified(validated, integrityVerified: false),
                                             duration: 0.1, statusCode: 200)
        XCTAssertEqual(try await persistence.snapshot(sourceID: source.id), validated)

        let failed = try await registry.recordRefresh(id: source.id, outcome: .failed("HTTP 503", .http),
                                                      duration: 0.2, statusCode: 503)
        XCTAssertEqual(try await persistence.snapshot(sourceID: source.id), validated)
        XCTAssertEqual(failed.health.httpFailures, 1)
        XCTAssertEqual(failed.health.consecutiveFailures, 1)
        XCTAssertEqual(failed.health.availability, .unavailable)
        XCTAssertEqual(failed.validationState, .invalid)

        let throttled = try await registry.recordRefresh(
            id: source.id, outcome: .failed("HTTP 429", .rateLimited), duration: 0.2, statusCode: 429)
        XCTAssertEqual(throttled.health.httpFailures, 2,
                       "rate limiting is an HTTP-family failure but must keep its own category")
        XCTAssertEqual(throttled.validationState, .invalid)

        _ = try await registry.recordRefresh(id: source.id, outcome: .failed("unsupported", .schema),
                                             duration: 0.2, statusCode: 200)
        let withSchemaFailure = try await registry.all()
        XCTAssertEqual(withSchemaFailure.first?.health.schemaFailures, 1)

        try await registry.remove(id: source.id)
        XCTAssertNil(try await persistence.snapshot(sourceID: source.id))
        XCTAssertTrue(try await persistence.sources().isEmpty)
    }

    func testReconcileDetectsCanonicalURLChangeAndDropsOldSnapshot() async throws {
        let persistence = CatalogPersistence(database: EcosystemDatabase())
        let registry = CatalogSourceRegistry(persistence: persistence)
        let source = try await registry.add(url: URL(string: sourceOne)!, name: "Example")
        let validated = try snapshot(
            feed(versions: "{\"version\":\"1.0\",\"downloadURL\":\"https://cdn.example.test/v1.ipa\"}"),
            url: sourceOne
        )
        _ = try await registry.recordRefresh(id: source.id, outcome: .verified(validated, integrityVerified: false),
                                             duration: 0, statusCode: 200)
        XCTAssertNotNil(try await persistence.snapshot(sourceID: source.id))

        let record = RepositoryRecord(id: "record-1", name: "Example", identifier: nil,
                                      sourceURL: URL(string: sourceTwo)!, iconURL: nil, date: nil)
        let reconciled = try await registry.reconcile(configured: [record])
        XCTAssertEqual(reconciled.first?.id, source.id)
        XCTAssertEqual(reconciled.first?.validationState, .unverified)
        XCTAssertNil(try await persistence.snapshot(sourceID: source.id))
    }

    func testDuplicateAddressAndURLChangeAreHandledWithoutLosingIdentity() async throws {
        let persistence = CatalogPersistence(database: EcosystemDatabase())
        let registry = CatalogSourceRegistry(persistence: persistence)
        let first = try await registry.add(url: URL(string: sourceOne)!, name: "First")
        XCTAssertThrowsError(try await registry.add(url: URL(string: sourceOne)!, name: "Duplicate"))
        let changed = try await registry.changeURL(id: first.id, to: URL(string: sourceTwo)!)
        XCTAssertEqual(changed.id, first.id)
        XCTAssertEqual(changed.validationState, .unverified)
        XCTAssertThrowsError(try await registry.update(id: first.id, name: "   "))
        XCTAssertThrowsError(try await registry.update(id: first.id, artworkURL: "file:///tmp/a.png"))
    }

    func testRefreshServiceValidatesBeforePublishingAndKeepsLastGoodCatalog() async throws {
        let persistence = CatalogPersistence(database: EcosystemDatabase())
        let registry = CatalogSourceRegistry(persistence: persistence)
        let source = try await registry.add(url: URL(string: sourceOne)!, name: "Example")
        let valid = feed(versions: "{\"version\":\"1.0\",\"downloadURL\":\"https://cdn.example.test/v1.ipa\"}")
        let broken = Data("{\"name\":\"Example\",\"apps\":[{\"name\":\"X\"}]}".utf8)

        var payload = valid
        let service = CatalogRefreshService(
            fetcher: { _, _ in .success(payload) },
            registry: registry,
            persistence: persistence,
            maximumAttempts: 1
        )
        let first = try await service.refresh(sourceID: source.id)
        guard case .verified(let snapshot, _) = first else { return XCTFail("expected a verified snapshot") }
        XCTAssertEqual(snapshot.apps.count, 1)

        payload = broken
        let second = try await service.refresh(sourceID: source.id)
        guard case .failed(_, let category) = second else { return XCTFail("expected a parse failure") }
        XCTAssertEqual(category, .parse)
        XCTAssertEqual(try await persistence.snapshot(sourceID: source.id), snapshot)
    }

    // MARK: Search, downloads and updates

    private func listing(url: String, version: String, hash: String? = nil) throws -> CatalogAppRecord {
        let data = feed(name: "Source", versions: """
        {"version":"\(version)","downloadURL":"https://cdn.example.test/app.ipa","size":100\(hash.map { ",\"sha256\":\"\($0)\"" } ?? "")}
        """)
        return try snapshot(data, url: url).apps[0]
    }

    func testSearchKeepsEverySourceListingAndFiltersBySource() throws {
        let one = try listing(url: sourceOne, version: "1.0")
        let two = try listing(url: sourceTwo, version: "2.0")
        let all = CatalogSearch.search(snapshots: [], query: CatalogSearchQuery())
        XCTAssertTrue(all.isEmpty)

        let hits = CatalogSearch.search(apps: [one, two], query: CatalogSearchQuery(text: "example"))
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].listings.count, 2)

        let filtered = CatalogSearch.search(apps: [one, two], query: CatalogSearchQuery(
            text: "com.example", sourceIDs: [one.sourceID], sort: .updated
        ))
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0].listings.map(\.app.sourceID), [one.sourceID])
    }

    func testDownloadResolverUsesSelectedReleaseAndRejectsUnsafeURLs() throws {
        let app = try listing(url: sourceOne, version: "1.0", hash: "abc123")
        let older = try XCTUnwrap(app.releases.first)
        let request = try CatalogDownloadResolver.resolve(app: app, release: older, integrityVerified: true)
        XCTAssertEqual(request.url.absoluteString, older.downloadURL)
        XCTAssertEqual(request.version, "1.0")
        XCTAssertEqual(request.expectation.sha256, "abc123")
        XCTAssertTrue(request.integrityVerified)

        var tampered = app
        var releases = app.releases
        releases[0] = CatalogRelease(
            version: releases[0].version, date: nil, downloadURL: "file:///tmp/evil.ipa",
            size: nil, sha256: nil, changelog: nil, minimumOSVersion: nil, supportedDevices: [], installName: nil
        )
        tampered = CatalogAppRecord(
            id: app.id, sourceID: app.sourceID, sourceName: app.sourceName, sourceURL: app.sourceURL,
            bundleIdentifier: app.bundleIdentifier, name: app.name, developer: app.developer,
            summary: app.summary, description: app.description, iconURL: app.iconURL,
            screenshotURLs: app.screenshotURLs, category: app.category, tintColor: app.tintColor,
            releases: releases, permissions: app.permissions, extra: app.extra,
            fetchedAt: app.fetchedAt, metadataIsVerified: app.metadataIsVerified
        )
        XCTAssertThrowsError(try CatalogDownloadResolver.resolve(app: tampered))
    }

    func testUpdateDetectorUsesRealVersionsAndReportsBlockers() throws {
        let app = try listing(url: sourceOne, version: "2.0")
        let installed = CatalogInstalledApp(name: "Installed", bundleIdentifier: "com.example.app",
                                             version: "1.0", sourceURL: sourceOne, recordID: "record")
        let candidates = CatalogUpdateDetector.detect(installed: [installed], apps: [app],
                                                       currentOSVersion: "17.0", signingIdentityAvailable: true)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].verdict, .updateAvailable)
        XCTAssertEqual(candidates[0].release.version, "2.0")

        let current = CatalogInstalledApp(name: "Installed", bundleIdentifier: "com.example.app",
                                           version: "2.0", sourceURL: sourceOne, recordID: "record")
        XCTAssertEqual(CatalogUpdateDetector.detect(
            installed: [current], apps: [app], currentOSVersion: "17.0", signingIdentityAvailable: true
        ).first?.verdict, .upToDate)

        let unknown = CatalogInstalledApp(name: "Installed", bundleIdentifier: "com.example.app",
                                           version: nil, sourceURL: sourceOne, recordID: "record")
        XCTAssertEqual(CatalogUpdateDetector.detect(
            installed: [unknown], apps: [app], currentOSVersion: "17.0", signingIdentityAvailable: true
        ).first?.verdict, .unknownVersion)

        let foreignSource = CatalogInstalledApp(name: "Installed", bundleIdentifier: "com.example.app",
                                                 version: "1.0", sourceURL: sourceTwo, recordID: "record")
        XCTAssertEqual(CatalogUpdateDetector.detect(
            installed: [foreignSource], apps: [app], currentOSVersion: "17.0", signingIdentityAvailable: true
        ).first?.verdict, .incompatible)

        XCTAssertEqual(CatalogUpdateDetector.detect(
            installed: [installed], apps: [app], currentOSVersion: "17.0", signingIdentityAvailable: false
        ).first?.verdict, .incompatible)
    }
}
