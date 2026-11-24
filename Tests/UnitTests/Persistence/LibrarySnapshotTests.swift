import Foundation
import XCTest
import AltSourceKit
@testable import VexSign

final class LibrarySnapshotTests: XCTestCase {
    /// Use the actual repository schema: iconURL is required even for offline matching tests.
    private func sourceApp(identifier: String, version: String) throws -> ASRepository.App {
        let json = try JSONSerialization.data(withJSONObject: [
            "bundleIdentifier": identifier, "name": "Example", "version": version,
            "iconURL": "https://example.invalid/icon.png"
        ])
        return try JSONDecoder().decode(ASRepository.App.self, from: json)
    }

    func testUpdateMatchingCanRunWithValueSnapshotsOnWorker() async throws {
        let app = try sourceApp(identifier: "com.vendor.app", version: "2.0")
        let installed = AppUpdateChecker.InstalledSnapshot(
            version: "1.0", uuid: "fixture", name: "Renamed clone", identifier: "com.me.clone",
            originalIdentifier: "com.vendor.app", source: URL(string: "https://example.invalid/source.json"))
        let preferences = AppUpdateChecker.MatchingSnapshot(includeNoDownload: false, nameMatchingMode: .off)
        let match = await Task.detached {
            AppUpdateChecker.shared.findInstalledApp(for: app, signedApps: [installed], importedApps: [], prefs: preferences)
        }.value
        XCTAssertEqual(match?.uuid, "fixture")
        XCTAssertEqual(match?.version, "1.0")
        XCTAssertEqual(match?.identifier, "com.me.clone")
    }

    func testUpdateMatchingUsesCapturedNamePreference() throws {
        let app = try sourceApp(identifier: "com.other.app", version: "2.0")
        let installed = AppUpdateChecker.InstalledSnapshot(
            version: "1.0", uuid: "fixture", name: "Example", identifier: "com.me.app",
            originalIdentifier: nil, source: nil)
        let exact = AppUpdateChecker.MatchingSnapshot(includeNoDownload: false, nameMatchingMode: .exact)
        let identifierOnly = AppUpdateChecker.MatchingSnapshot(includeNoDownload: false, nameMatchingMode: .off)
        XCTAssertNotNil(AppUpdateChecker.shared.findInstalledApp(for: app, signedApps: [], importedApps: [installed], prefs: exact))
        XCTAssertNil(AppUpdateChecker.shared.findInstalledApp(for: app, signedApps: [], importedApps: [installed], prefs: identifierOnly))
    }

    func testExactIdentityWinsAndAmbiguousNamesFailClosed() throws {
        let app = try sourceApp(identifier: "com.vendor.app", version: "2.0")
        let exact = AppUpdateChecker.InstalledSnapshot(version: "1.0", uuid: "exact", name: "Example",
                                                     identifier: "com.vendor.app", originalIdentifier: nil, source: nil)
        let other = AppUpdateChecker.InstalledSnapshot(version: "9.0", uuid: "other", name: "Example",
                                                     identifier: "com.other.app", originalIdentifier: nil, source: nil)
        let prefs = AppUpdateChecker.MatchingSnapshot(includeNoDownload: true, nameMatchingMode: .exact)
        XCTAssertEqual(AppUpdateChecker.shared.findInstalledApp(for: app, signedApps: [exact, other], importedApps: [], prefs: prefs)?.uuid, "exact")
        let renamed = AppUpdateChecker.InstalledSnapshot(version: "1.0", uuid: "third", name: "Example",
                                                       identifier: "com.third.app", originalIdentifier: nil, source: nil)
        XCTAssertNil(AppUpdateChecker.shared.findInstalledApp(for: app, signedApps: [other, renamed], importedApps: [], prefs: prefs))
    }

    func testSelectedVersionAndUUIDComeFromSameRecord() throws {
        let app = try sourceApp(identifier: "com.vendor.app", version: "3.0")
        let old = AppUpdateChecker.InstalledSnapshot(version: "1.0", uuid: "old", name: "Old", identifier: "com.vendor.app", originalIdentifier: nil, source: nil)
        let newer = AppUpdateChecker.InstalledSnapshot(version: "2.0", uuid: "newer", name: "New", identifier: "com.vendor.app", originalIdentifier: nil, source: nil)
        let index = AppUpdateChecker.InstalledIndex(signed: [old], imported: [newer])
        let match = AppUpdateChecker.shared.findInstalledApp(for: app, signedApps: [], importedApps: [],
                                                           prefs: .init(includeNoDownload: true), index: index)
        XCTAssertEqual(match?.version, "2.0")
        XCTAssertEqual(match?.uuid, "newer")
    }

    private func sourceRepository(sourceURL: URL) throws -> ASRepository {
        let json = try JSONSerialization.data(withJSONObject: [
            "name": "Fixture Repository",
            "identifier": "fixture.repository",
            "apps": [[
                "bundleIdentifier": "com.example.app",
                "name": "Example",
                "version": "1.0",
                "iconURL": "https://example.invalid/icon.png"
            ]]
        ])
        var repository = try JSONDecoder().decode(ASRepository.self, from: json)
        repository.sourceURL = sourceURL
        return repository
    }

    func testVersionComparisonSupportsVPrefixAndSemVerPrereleases() {
        let checker = AppUpdateChecker.shared
        XCTAssertTrue(checker.hasUpdate(installedVersion: "1.9", sourceVersion: "v2.0"))
        XCTAssertFalse(checker.hasUpdate(installedVersion: "2.1.1", sourceVersion: "2.1.1-beta.1"))
        XCTAssertTrue(checker.hasUpdate(installedVersion: "2.1.0", sourceVersion: "2.1.1-beta.1"))
        XCTAssertTrue(checker.hasUpdate(installedVersion: "2.1.0-beta.2", sourceVersion: "2.1.0-beta.10"))
        XCTAssertFalse(checker.hasUpdate(installedVersion: "2.1.0+build.5", sourceVersion: "2.1.0+build.7"))
        XCTAssertFalse(checker.hasUpdate(installedVersion: "unknown", sourceVersion: "v2.0"))
    }

    func testRepositorySnapshotsWithLossyFilenameCollisionStayDistinct() throws {
        let firstID = "source/a"
        let secondID = "source?a"
        let firstPayload = try JSONSerialization.data(withJSONObject: [
            "name": "First source",
            "apps": [["bundleIdentifier": "com.example.first", "name": "First", "version": "1", "iconURL": "https://example.invalid/first.png"]]
        ])
        let secondPayload = try JSONSerialization.data(withJSONObject: [
            "name": "Second source",
            "apps": [["bundleIdentifier": "com.example.second", "name": "Second", "version": "1", "iconURL": "https://example.invalid/second.png"]]
        ])
        defer {
            RepositorySnapshotCache.remove(identifier: firstID)
            RepositorySnapshotCache.remove(identifier: secondID)
        }

        RepositorySnapshotCache.store(identifier: firstID, sourceURL: nil, payload: firstPayload)
        RepositorySnapshotCache.store(identifier: secondID, sourceURL: nil, payload: secondPayload)

        XCTAssertEqual(RepositorySnapshotCache.load(identifier: firstID)?.repository.name, "First source")
        XCTAssertEqual(RepositorySnapshotCache.load(identifier: secondID)?.repository.name, "Second source")
    }

    func testUpdateChecksExcludeCatalogsFromRemovedSources() throws {
        let activeURL = try XCTUnwrap(URL(string: "https://active.example/source.json"))
        let removedURL = try XCTUnwrap(URL(string: "https://removed.example/source.json"))
        let active = try sourceRepository(sourceURL: activeURL)
        let removed = try sourceRepository(sourceURL: removedURL)

        let selected = AppUpdateChecker.configuredRepositories(
            in: [removed, active],
            sourceURLs: Set([activeURL])
        )
        XCTAssertEqual(selected.count, 1)
        XCTAssertEqual(selected.first?.sourceURL, activeURL)
        XCTAssertTrue(AppUpdateChecker.configuredRepositories(in: [removed], sourceURLs: []).isEmpty)
    }

    func testDirectorySizesAreMeasuredAsAnIndependentValueSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) } // try? ok: test teardown only
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 8192).write(to: root.appendingPathComponent("fixture"))
        let entries = [LibrarySizeSnapshot.Entry(id: "a", directory: root),
                       LibrarySizeSnapshot.Entry(id: "a", directory: root)]
        let result = try await LibrarySizeSnapshot.measure(entries)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result["a"], FileManager.default.allocatedSize(at: root))
        XCTAssertGreaterThan(result["a"] ?? 0, 0)
        let empty = try await LibrarySizeSnapshot.measure([])
        XCTAssertTrue(empty.isEmpty)
    }
}
