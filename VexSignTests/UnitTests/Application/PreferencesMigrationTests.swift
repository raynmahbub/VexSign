//
//  PreferencesMigrationTests.swift
//  VexSignTests
//
//  Upgrade tests for representative legacy preference stores. They use an
//  isolated UserDefaults suite: no user, simulator or device data is touched.
//

import XCTest
@testable import VexSign

final class PreferencesMigrationTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "VexSignPreferencesMigrationTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        XCTAssertNotNil(defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testLegacyFeatherAndRyukValuesAreAdopted() {
        defaults.set("legacy-cert", forKey: "feather.selectedCert")
        defaults.set(true, forKey: "RyukSign.onboardingCompleted")
        defaults.set("header", forKey: "Feather.downloadDisplayMode")

        let migrated = LegacyPreferenceMigration.migrate(in: defaults)

        XCTAssertEqual(Set(migrated), [
            "vexsign.selectedCert", "VexSign.onboardingCompleted", "VexSign.downloadDisplayMode"
        ])
        XCTAssertEqual(defaults.string(forKey: "vexsign.selectedCert"), "legacy-cert")
        XCTAssertTrue(defaults.bool(forKey: "VexSign.onboardingCompleted"))
        XCTAssertEqual(defaults.string(forKey: "VexSign.downloadDisplayMode"), "header")
        // The old keys remain: a failed later step can still retry safely.
        XCTAssertEqual(defaults.string(forKey: "feather.selectedCert"), "legacy-cert")
    }

    func testMigrationIsIdempotentAndDoesNotOverwriteCurrentValues() {
        defaults.set("current-cert", forKey: "vexsign.selectedCert")
        defaults.set("legacy-cert", forKey: "feather.selectedCert")

        let first = LegacyPreferenceMigration.migrate(in: defaults)
        let second = LegacyPreferenceMigration.migrate(in: defaults)

        XCTAssertFalse(first.contains("vexsign.selectedCert"))
        XCTAssertTrue(second.isEmpty)
        XCTAssertEqual(defaults.string(forKey: "vexsign.selectedCert"), "current-cert")
    }

    func testMalformedLegacyValueCannotPoisonCurrentStore() {
        defaults.set(["unexpected": "shape"], forKey: "Feather.dynamicOverlaySize")
        let migrated = LegacyPreferenceMigration.migrate(in: defaults)
        XCTAssertTrue(migrated.contains("VexSign.dynamicOverlaySize"))
        XCTAssertNotNil(defaults.object(forKey: "VexSign.dynamicOverlaySize"))
    }

    func testBuildMetadataValidationRejectsUnsafeValues() {
        XCTAssertEqual(VexSignBuildInfo.validatedToken("1.2.1"), "1.2.1")
        XCTAssertEqual(VexSignBuildInfo.validatedToken("bad\nvalue"), "unknown")
        XCTAssertEqual(VexSignBuildInfo.validatedCommit("ABCDEF0123456789"), "abcdef0123456789")
        XCTAssertEqual(VexSignBuildInfo.validatedCommit("$(VEXSIGN_SOURCE_COMMIT)"), "unknown")
    }
}
