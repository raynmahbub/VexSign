import Foundation
import XCTest
import AltSourceKit
@testable import VexSign

final class AppUpdateMatcherTests: XCTestCase {
    func testSnapshotMatcherComparesUpdatesWithoutCoreDataObjects() throws {
        let repositoryData = try JSONSerialization.data(withJSONObject: [
            "name": "Example",
            "identifier": "example.repository",
            "sourceURL": "https://example.com/apps.json",
            "apps": [[
                "name": "Example App",
                "bundleIdentifier": "com.example.app",
                "developerName": "Example",
                "versions": [[
                    "version": "2.0",
                    "date": "2026-11-01",
                    "downloadURL": "https://example.com/Example.ipa"
                ]]
            ]]
        ])
        let repository = try JSONDecoder().decode(ASRepository.self, from: repositoryData)
        let app = try XCTUnwrap(repository.apps.first)
        let installed = InstalledAppSnapshot(
            version: "1.0",
            uuid: "installed-app-1",
            name: "Example App",
            identifier: "com.example.app",
            originalIdentifier: nil,
            sourceURL: URL(string: "https://example.com/apps.json")
        )
        let preferences = UpdateMatchingSnapshot(
            nameMatchingMode: .balanced,
            sameDeveloper: false,
            samePlaceItCameFrom: true,
            includeBetas: false,
            includeNoDownload: false,
            strictHiding: false,
            hiddenAppUUIDs: []
        )

        XCTAssertTrue(AppUpdateChecker.computeUpdate(
            app: app,
            source: repository,
            installedApps: [installed],
            preferences: preferences
        ))

        let hiddenPreferences = UpdateMatchingSnapshot(
            nameMatchingMode: .balanced,
            sameDeveloper: false,
            samePlaceItCameFrom: true,
            includeBetas: false,
            includeNoDownload: false,
            strictHiding: true,
            hiddenAppUUIDs: ["installed-app-1"]
        )
        XCTAssertFalse(AppUpdateChecker.computeUpdate(
            app: app,
            source: repository,
            installedApps: [installed],
            preferences: hiddenPreferences
        ), "Strictly hidden apps must not be surfaced by the detached matcher")
    }
}
