import Foundation
import XCTest
import AltSourceKit
@testable import VexSign

final class LibrarySnapshotTests: XCTestCase {
    func testUpdateMatchingCanRunWithValueSnapshotsOnWorker() async throws {
        let app = try JSONDecoder().decode(ASRepository.App.self, from: Data(
            #"{"bundleIdentifier":"com.vendor.app","name":"Example","version":"2.0"}"#.utf8))
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
        let app = try JSONDecoder().decode(ASRepository.App.self, from: Data(
            #"{"bundleIdentifier":"com.other.app","name":"Example","version":"2.0"}"#.utf8))
        let installed = AppUpdateChecker.InstalledSnapshot(
            version: "1.0", uuid: "fixture", name: "Example", identifier: "com.me.app",
            originalIdentifier: nil, source: nil)
        let exact = AppUpdateChecker.MatchingSnapshot(includeNoDownload: false, nameMatchingMode: .exact)
        let identifierOnly = AppUpdateChecker.MatchingSnapshot(includeNoDownload: false, nameMatchingMode: .off)
        XCTAssertNotNil(AppUpdateChecker.shared.findInstalledApp(for: app, signedApps: [], importedApps: [installed], prefs: exact))
        XCTAssertNil(AppUpdateChecker.shared.findInstalledApp(for: app, signedApps: [], importedApps: [installed], prefs: identifierOnly))
    }

    func testExactIdentityWinsAndAmbiguousNamesFailClosed() throws {
        let app = try JSONDecoder().decode(ASRepository.App.self, from: Data(
            #"{"bundleIdentifier":"com.vendor.app","name":"Example","version":"2.0"}"#.utf8))
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
        let app = try JSONDecoder().decode(ASRepository.App.self, from: Data(
            #"{"bundleIdentifier":"com.vendor.app","name":"Example","version":"3.0"}"#.utf8))
        let old = AppUpdateChecker.InstalledSnapshot(version: "1.0", uuid: "old", name: "Old", identifier: "com.vendor.app", originalIdentifier: nil, source: nil)
        let newer = AppUpdateChecker.InstalledSnapshot(version: "2.0", uuid: "newer", name: "New", identifier: "com.vendor.app", originalIdentifier: nil, source: nil)
        let index = AppUpdateChecker.InstalledIndex(signed: [old], imported: [newer])
        let match = AppUpdateChecker.shared.findInstalledApp(for: app, signedApps: [], importedApps: [],
                                                           prefs: .init(includeNoDownload: true), index: index)
        XCTAssertEqual(match?.version, "2.0")
        XCTAssertEqual(match?.uuid, "newer")
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
