//
//  UpdateAvailabilityTests.swift
//  VexSign
//
//  Stable bundle identity, central version/build comparison, source
//  availability, compatibility, dismissal and re-check after install.
//

import Foundation
import XCTest
@testable import VexSign

@MainActor
final class UpdateAvailabilityTests: XCTestCase {
    private func candidate(version: String = "2.1.0", build: String? = "42",
                           bundleID: String = "com.example.app", hasURL: Bool = true) -> UpdateCandidate {
        UpdateCandidate(
            bundleID: bundleID,
            name: "Example",
            version: version,
            build: build,
            downloadURL: hasURL ? URL(string: "https://example.test/app.ipa") : nil
        )
    }

    private func installed(version: String? = "2.0.0", build: String? = "40",
                           bundleID: String = "com.example.app") -> InstalledAppVersion {
        InstalledAppVersion(bundleID: bundleID, version: version, build: build)
    }

    func testVersionUpgradeIsAvailable() {
        let result = UpdateAvailabilityEvaluator.evaluate(candidate: candidate(), installed: installed())
        XCTAssertEqual(result, .available(reason: "version"))
        XCTAssertNotNil(UpdateAvailabilityEvaluator.message(for: result, candidate: candidate()))
    }

    func testSameVersionNewerBuildIsAvailable() {
        let result = UpdateAvailabilityEvaluator.evaluate(
            candidate: candidate(version: "2.0.0", build: "41"),
            installed: installed(version: "2.0.0", build: "40")
        )
        XCTAssertEqual(result, .available(reason: "build"))
    }

    func testDowngradeAndMissingDownloadAreNotUpdates() {
        XCTAssertEqual(
            UpdateAvailabilityEvaluator.evaluate(candidate: candidate(version: "1.0"), installed: installed()),
            .downgrade
        )
        XCTAssertEqual(
            UpdateAvailabilityEvaluator.evaluate(candidate: candidate(hasURL: false), installed: installed()),
            .unavailableFromSource
        )
    }

    func testUnknownIdentityNeverFallsBackToName() {
        XCTAssertEqual(
            UpdateAvailabilityEvaluator.evaluate(candidate: candidate(bundleID: "com.example.other"), installed: installed()),
            .unknownIdentity
        )
        XCTAssertEqual(UpdateAvailabilityEvaluator.normalizedBundleID(" COM.Example.App "), "com.example.app")
    }

    func testInvalidVersionAndIncompatibleBuildAreRejected() {
        XCTAssertEqual(
            UpdateAvailabilityEvaluator.evaluate(candidate: candidate(version: "not a version"), installed: installed()),
            .invalidVersion
        )
        XCTAssertEqual(
            UpdateAvailabilityEvaluator.evaluate(candidate: candidate(), installed: installed()) { _ in false },
            .incompatible
        )
    }

    func testDismissalIsStableAndInstallClearsIt() {
        let suite = "VexSignTests.updates.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = UpdateDismissalStore(defaults: defaults)
        let item = candidate()

        XCTAssertTrue(store.canNotify(for: item))
        store.dismiss(UpdateAvailabilityEvaluator.stableKey(candidate: item))
        XCTAssertFalse(store.canNotify(for: item))
        XCTAssertFalse(store.canNotify(for: candidate(version: "2.1.0", build: "42")), "stable key ignores formatting")

        store.rememberInstalled(key: UpdateAvailabilityEvaluator.stableKey(candidate: item), bundleID: item.bundleID)
        store.clearDismissals(bundleID: item.bundleID)
        XCTAssertTrue(store.canNotify(for: item), "a later check after installation is never suppressed")
    }
}
