//
//  ReleaseCompatibilityTests.swift
//  VexSignTests
//
//  A source's `versions` array is newest-first — that is the contract AltStore's own
//  `setVersions` relies on — and `minOSVersion` narrows which of those releases this device can
//  actually install. These tests pin both halves: the order is never re-derived from version
//  strings, and a release that declares a newer minimum is skipped in favour of one that runs.
//
//  The source JSON is the real schema, decoded through `JSONDecoder` rather than through a
//  memberwise initialiser, so a change to the decoder fails here too.
//

import XCTest
import AltSourceKit

final class ReleaseCompatibilityTests: XCTestCase {
    // MARK: - Fixtures

    private func release(
        _ version: String,
        build: String? = nil,
        minOS: String? = nil,
        path: String
    ) -> [String: Any] {
        var dictionary: [String: Any] = [
            "version": version,
            "downloadURL": "https://example.invalid/\(path)"
        ]
        if let build { dictionary["buildVersion"] = build }
        if let minOS { dictionary["minOSVersion"] = minOS }
        return dictionary
    }

    private func app(_ versions: [[String: Any]]) throws -> ASRepository.App {
        let json = try JSONSerialization.data(withJSONObject: [
            "bundleIdentifier": "com.vendor.app",
            "name": "Vendor App",
            "iconURL": "https://example.invalid/icon.png",
            "versions": versions
        ])
        return try JSONDecoder().decode(ASRepository.App.self, from: json)
    }

    private func device(_ major: UInt, _ minor: UInt = 0, _ patch: UInt = 0) -> OSVersion {
        OSVersion(major: major, minor: minor, patch: patch)
    }

    /// The shape a real source has: the current release first, an older one behind it, and a
    /// release that only runs on a newer OS than most devices have.
    private func typicalApp() throws -> ASRepository.App {
        try app([
            release("2.0", build: "2", minOS: "26.0", path: "2.0.ipa"),
            release("1.5", build: "9", minOS: "17.0", path: "1.5.ipa"),
            release("1.4", build: "4", path: "1.4.ipa")
        ])
    }

    // MARK: - Compatibility filtering

    func testTheNewestReleaseIsOfferedWhenThisDeviceSupportsIt() throws {
        let app = try typicalApp()
        XCTAssertEqual(app.newestSupportedRelease(running: device(26, 0))?.version, "2.0")
        XCTAssertTrue(app.hasSupportedRelease(running: device(26, 0)))
    }

    func testAnOlderSupportedReleaseIsOfferedWhenTheNewestNeedsANewerOS() throws {
        // The whole point: iOS 18 cannot install the 26.0-only release, so offering it means a
        // download that fails after the user has waited for it.
        let app = try typicalApp()
        XCTAssertEqual(app.newestSupportedRelease(running: device(18, 5))?.version, "1.5")
        XCTAssertEqual(app.newestSupportedRelease(running: device(18, 5))?.downloadURL?.lastPathComponent, "1.5.ipa")
    }

    func testAReleaseWithoutAMinimumIsTreatedAsSupported() throws {
        let app = try typicalApp()
        // 1.4 declares no minimum at all, so it is the usable release on a 16.x device.
        XCTAssertEqual(app.newestSupportedRelease(running: device(16, 7))?.version, "1.4")
        XCTAssertTrue(app.hasSupportedRelease(running: device(16, 7)))
    }

    func testTheMinimumIsComparedAtPatchLevel() throws {
        let app = try app([release("3.0", minOS: "18.0.1", path: "3.0.ipa")])
        // The only release needs a patch newer than this device has: nothing is supported, and
        // the fallback still returns it rather than making the app unavailable.
        XCTAssertFalse(app.hasSupportedRelease(running: device(18, 0)))
        XCTAssertEqual(app.newestSupportedRelease(running: device(18, 0))?.version, "3.0")
        XCTAssertTrue(app.hasSupportedRelease(running: device(18, 0, 1)))
    }

    func testNoSupportedReleaseStillReturnsTheNewestInsteadOfNothing() throws {
        // A source with unparsable or aspirational metadata must behave as it did before this
        // filter existed. Turning it into "no download" would remove a working path from every
        // app on a source that labels its minimum wrongly.
        let app = try app([release("9.0", minOS: "99.0", path: "9.0.ipa")])
        XCTAssertEqual(app.newestSupportedRelease(running: device(18))?.version, "9.0")
        XCTAssertFalse(app.hasSupportedRelease(running: device(18)))
    }

    func testAnEmptyVersionListHasNoRelease() throws {
        let app = try app([])
        XCTAssertNil(app.newestSupportedRelease(running: device(18)))
        XCTAssertFalse(app.hasSupportedRelease(running: device(18)))
    }

    // MARK: - Source order is the contract

    func testSourceOrderIsNeverReorderedByVersionString() throws {
        // `1.10` sorts before `1.9` as a string, and re-sorting here would silently pick the
        // older release from a correctly ordered source. Source order wins.
        let app = try app([
            release("1.10", path: "1.10.ipa"),
            release("1.9", path: "1.9.ipa")
        ])
        XCTAssertEqual(app.newestSupportedRelease(running: device(18))?.version, "1.10")
    }

    func testTheAccessorAgreesWithTheTestedRule() throws {
        // `currentAppVersion` reads the running system, which a test cannot choose; assert the
        // two agree rather than re-deriving the answer a second way.
        let app = try typicalApp()
        XCTAssertEqual(app.currentAppVersion?.version,
                       app.newestSupportedRelease(running: .running)?.version)
    }

    // MARK: - OSVersion ordering

    func testOSVersionsOrderComponentWise() {
        XCTAssertTrue(device(18, 0) < device(18, 1))
        XCTAssertTrue(device(18, 9) < device(26, 0))
        XCTAssertTrue(device(18, 0) < device(18, 0, 1))
        XCTAssertFalse(device(18, 0, 0) < device(18, 0))
        XCTAssertFalse(device(18, 1) < device(18, 0))
        XCTAssertEqual(device(18, 0, 0), device(18, 0))
    }

    func testRunningOSVersionIsAPlausibleIOSVersion() {
        // Guards the `running` bridge from a sign or component-width mistake; iOS 15 is the
        // oldest deployment target in this project.
        XCTAssertGreaterThanOrEqual(OSVersion.running.majorVersion, 15)
    }

    func testAnUnparsableMinimumDecodesAsZeroAndStaysSupported() throws {
        // The decoder is lenient by construction (`UInt` conversion of each component). This
        // pins the consequence: junk in `minOSVersion` must not hide a release.
        let app = try app([release("4.0", minOS: "seventeen", path: "4.0.ipa")])
        XCTAssertTrue(app.hasSupportedRelease(running: device(15)))
    }
}
