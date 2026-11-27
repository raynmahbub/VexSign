//
//  ModificationProfileTests.swift
//  VexSignTests
//

import Foundation
import XCTest
@testable import VexSign

final class ModificationProfileTests: XCTestCase {
    private func store() -> ModificationProfileStore {
        ModificationProfileStore(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("ProfileTest_\(UUID().uuidString)", isDirectory: true)
        )
    }

    private func entry(tweakID: UUID, versionID: UUID) -> ModificationProfileEntry {
        ModificationProfileEntry(tweakID: tweakID, versionID: versionID)
    }

    func testProfileRoundTripsWithoutStoringPathsOrSecrets() throws {
        let store = store()
        let tweakID = UUID(), versionID = UUID()
        let profile = ModificationProfile(
            name: "Fixture", appBundleIdentifier: "com.example.app",
            entries: [entry(tweakID: tweakID, versionID: versionID)]
        )
        XCTAssertEqual(try store.upsert(profile), [profile])
        XCTAssertEqual(try store.load(), [profile])
        let data = try Data(contentsOf: store.directory.appendingPathComponent("profiles.json"))
        XCTAssertFalse(String(data: data, encoding: .utf8)?.contains("/var/") ?? true)
        XCTAssertFalse(String(data: data, encoding: .utf8)?.contains("password") ?? true)
    }

    func testDuplicateAndDeleteAreStable() throws {
        let store = store()
        let profile = ModificationProfile(
            name: "Original", appBundleIdentifier: "com.example.app",
            entries: [entry(tweakID: UUID(), versionID: UUID())]
        )
        _ = try store.upsert(profile)
        let copy = profile.duplicating(name: "Copy")
        _ = try store.upsert(copy)
        XCTAssertEqual(try store.load().count, 2)
        _ = try store.remove(id: profile.id)
        XCTAssertEqual(try store.load().map(\.id), [copy.id])
    }

    func testBrokenReferencesArePrunedAfterPackageRemoval() throws {
        let store = store()
        let keepID = UUID(), keepVersion = UUID()
        let profile = ModificationProfile(
            name: "Mixed", appBundleIdentifier: "com.example.app",
            entries: [
                entry(tweakID: keepID, versionID: keepVersion),
                entry(tweakID: UUID(), versionID: UUID())
            ]
        )
        _ = try store.upsert(profile)
        let tweaks = [InjectionFixtures.tweak(id: keepID, versionID: keepVersion)]
        let pruned = try store.prune(against: tweaks)
        XCTAssertEqual(pruned.first?.entries.count, 1)
        XCTAssertEqual(pruned.first?.entries.first?.tweakID, keepID)
    }

    func testReplacedVersionInvalidatesReference() {
        let tweakID = UUID(), oldVersion = UUID(), newVersion = UUID()
        let tweak = InjectionFixtures.tweak(id: tweakID, versionID: newVersion)
        let status = ModificationProfileValidator.status(
            of: entry(tweakID: tweakID, versionID: oldVersion), against: [tweak]
        )
        guard case .broken(let reason) = status else { return XCTFail("stale version must be broken") }
        XCTAssertTrue(reason.contains("version"))
    }

    func testMalformedProfileFileFailsClosed() throws {
        let store = store()
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.directory.appendingPathComponent("profiles.json"))
        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? ModificationProfileStore.StoreError, .malformed)
        }
    }
}
