//
//  DiscoveryViewModelTests.swift
//  VexSignTests
//
//  A view model is constructible with a fake inward catalog port. Admission
//  uses the shared security policy, without the real session, persistence or
//  notification centre, and without duplicating validation inside the fake.
//

import Foundation
import XCTest
@testable import VexSign

@MainActor
final class DiscoveryViewModelTests: XCTestCase {
    private final class FakeCatalog: DiscoveryCatalogProviding {
        var downloads: [DiscoveryApp] = []
        var persistedSignals: [DiscoverySignals] = []
        var events: [String] = []
        var downloadFailure: Error?

        func cachedApps() async throws -> [DiscoveryApp] { [] }
        func signals() async throws -> DiscoverySignals { .init() }
        func refreshedApps(force: Bool) async throws -> [DiscoveryApp]? { nil }
        func saveApps(_ apps: [DiscoveryApp]) async throws {}
        func saveSignals(_ signals: DiscoverySignals) async throws {
            events.append("signals")
            persistedSignals.append(signals)
        }
        func download(_ app: DiscoveryApp) throws {
            events.append("download")
            downloads.append(app)
            if let downloadFailure { throw downloadFailure }
        }
    }

    private func makeModel(_ provider: FakeCatalog) -> DiscoveryViewModel {
        DiscoveryViewModel(useCase: DiscoveryUseCase(provider: provider, policy: SecurityPolicyGateway()))
    }

    private func app(download: String?) -> DiscoveryApp {
        DiscoveryApp(
            id: "source#com.example.app",
            source: "source",
            bundleIdentifier: "com.example.app",
            name: "Example",
            summary: "Example app",
            developer: "Example",
            category: "Utilities",
            version: "1.0",
            icon: nil,
            download: download.flatMap(URL.init(string:)),
            updated: nil,
            releases: 0
        )
    }

    func testAViewModelCanBeBuiltWithAFake() {
        let model = makeModel(FakeCatalog())
        XCTAssertTrue(model.apps.isEmpty)
        XCTAssertNil(model.error)
    }

    func testAnInvalidDownloadURLIsRefusedBeforeThePipelineIsTouched() async {
        let fake = FakeCatalog()
        let model = makeModel(fake)
        await model.download(app(download: "ftp://example.com/app.ipa"))
        XCTAssertTrue(fake.downloads.isEmpty)
        XCTAssertTrue(fake.persistedSignals.isEmpty)
        XCTAssertNotNil(model.error)
    }

    func testAnAppWithNoDownloadURLIsRefused() async {
        let fake = FakeCatalog()
        let model = makeModel(fake)
        await model.download(app(download: nil))
        XCTAssertTrue(fake.downloads.isEmpty)
        XCTAssertTrue(fake.persistedSignals.isEmpty)
        XCTAssertNotNil(model.error)
    }

    func testAValidDownloadReachesTheProviderOnceBeforeRecordingItsSignal() async {
        let fake = FakeCatalog()
        let model = makeModel(fake)
        let listing = app(download: "https://example.com/app.ipa")
        await model.download(listing)
        XCTAssertEqual(fake.downloads.count, 1)
        XCTAssertEqual(fake.downloads.first?.download, listing.download)
        XCTAssertEqual(fake.persistedSignals.count, 1)
        XCTAssertEqual(fake.persistedSignals.first?.downloads[listing.id], 1)
        XCTAssertEqual(fake.events, ["download", "signals"])
        XCTAssertNil(model.error)
    }

    func testAProviderRefusalDoesNotRecordASuccessfulDownloadSignal() async {
        let fake = FakeCatalog()
        fake.downloadFailure = URLError(.networkConnectionLost)
        let model = makeModel(fake)
        await model.download(app(download: "https://example.com/app.ipa"))
        XCTAssertEqual(fake.downloads.count, 1)
        XCTAssertTrue(fake.persistedSignals.isEmpty)
        XCTAssertTrue(model.signals.downloads.isEmpty)
        XCTAssertNotNil(model.error)
    }
}
