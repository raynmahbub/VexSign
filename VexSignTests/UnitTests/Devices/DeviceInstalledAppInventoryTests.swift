// Deterministic, credential-free tests for the library-app-scoped device
// inventory. Stub readings model protocol responses; they are not physical
// device validation.

import Foundation
import XCTest
#if canImport(DeviceFoundation)
@testable import DeviceFoundation
#else
@testable import IDeviceSwift
#endif
@testable import VexSign

@MainActor
final class DeviceInstalledAppInventoryTests: XCTestCase {
    private let digest = String(repeating: "a", count: 64)
    private let observedAt = Date(timeIntervalSince1970: 2_000_000)

    private func binding() throws -> DeviceSessionBinding {
        try XCTUnwrap(DeviceSessionBinding(
            deviceIdentifier: PairingRecordTestFixtures.device, pairingSHA256: digest
        ))
    }

    private func request() -> DeviceConnectionRequest {
        DeviceConnectionRequest(
            pairingFile: URL(fileURLWithPath: "/synthetic/pairing.plist"),
            expectedDeviceIdentifier: PairingRecordTestFixtures.device,
            protocolConsent: true, expectedPairingSHA256: digest
        )
    }

    private func libraryApp(
        id: String = "fixture-1",
        identifier: String? = "com.example.app",
        version: String? = "1.2",
        name: String = "Fixture App"
    ) -> LibraryAppRecord {
        LibraryAppRecord(id: id, uuid: nil, isSigned: true, name: name, version: version,
            identifier: identifier, originalIdentifier: identifier, date: nil, icon: nil,
            appDescription: nil, sortIndex: 0, source: nil, certificateID: nil,
            bundleURL: nil, artifactURL: nil)
    }

    private func reading(
        identifier: String = "com.example.app",
        version: String? = "1.2",
        build: String? = "7",
        binding: DeviceSessionBinding? = nil,
        path: String = "/private/var/containers/Bundle/Application/TEST/App.app"
    ) throws -> DeviceInstalledApplication {
        DeviceInstalledApplication(bundleIdentifier: identifier, name: "Device App", version: version,
            build: build, path: path, binding: binding ?? self.binding(), observedAt: observedAt)
    }

    func testMatchingReadingIsCurrentAndKeepsNoBundlePath() throws {
        let row = DeviceInstalledAppAssessment.make(
            for: libraryApp(), expectedBuild: "7", observed: try reading(),
            binding: try binding(), now: observedAt.addingTimeInterval(1)
        )
        XCTAssertEqual(row.state, .current)
        XCTAssertEqual(row.deviceVersion, "1.2")
        XCTAssertEqual(row.deviceBuild, "7")
        XCTAssertFalse(String(describing: row).contains("/private/var/"))
    }

    func testOtherVersionIsReportedWithoutClaimingOurArtifactInstalled() throws {
        let row = DeviceInstalledAppAssessment.make(
            for: libraryApp(), expectedBuild: "7", observed: try reading(version: "2.0"),
            binding: try binding(), now: observedAt.addingTimeInterval(1)
        )
        XCTAssertEqual(row.state, .otherVersion)
        XCTAssertTrue(row.detail.contains("another version") || row.detail.contains("another"))
    }

    func testUnknownMissingOrForeignBindingNeverBecomesNotInstalled() throws {
        let noReading = DeviceInstalledAppAssessment.make(
            for: libraryApp(), expectedBuild: "7", observed: nil, binding: try binding()
        )
        XCTAssertEqual(noReading.state, .unreported)
        XCTAssertFalse(noReading.detail.contains("not installed"))

        let foreign = DeviceSessionBinding(
            deviceIdentifier: PairingRecordTestFixtures.otherDevice, pairingSHA256: digest
        )
        let wrongDevice = DeviceInstalledAppAssessment.make(
            for: libraryApp(), expectedBuild: "7",
            observed: try reading(binding: try XCTUnwrap(foreign)), binding: try binding()
        )
        XCTAssertEqual(wrongDevice.state, .unreported)

        let noBuild = DeviceInstalledAppAssessment.make(
            for: libraryApp(), expectedBuild: "7", observed: try reading(build: nil),
            binding: try binding(), now: observedAt.addingTimeInterval(1)
        )
        XCTAssertEqual(noBuild.state, .unreported)
    }

    func testEligibleAppsAreValidatedDeduplicatedAndBounded() {
        let duplicate = libraryApp(id: "fixture-2")
        let invalid = libraryApp(id: "fixture-3", identifier: "not a bundle id")
        let many = (0..<70).map { libraryApp(id: "app-\($0)", identifier: "com.example.app\($0)") }
        let eligible = DeviceInstalledAppAssessment.eligible([libraryApp(), duplicate, invalid] + many)
        XCTAssertEqual(eligible.count, DeviceInstalledAppAssessment.maximumApps)
        XCTAssertEqual(eligible.first?.id, "fixture-1")
        XCTAssertFalse(eligible.contains { $0.identifier == "not a bundle id" })
    }

    func testRefreshPublishesOnlyFrozenDeviceReadingsAndRecordsNoNegative() async throws {
        let stub = StubInventoryQuery(results: [
            "com.example.app": try reading(),
            "com.example.second": nil
        ])
        let frozenRequest = request()
        let model = DeviceInventoryModel(query: stub, requestProvider: { frozenRequest })
        let apps = [libraryApp(), libraryApp(id: "fixture-2", identifier: "com.example.second")]

        model.refresh(apps: apps)
        for _ in 0..<200 {
            if !model.isRefreshing { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertFalse(model.isRefreshing)
        XCTAssertEqual(model.rows.count, 2)
        XCTAssertEqual(model.rows.first?.state, .current)
        XCTAssertEqual(model.rows.last?.state, .unreported)
        XCTAssertNotNil(model.refreshedAt)
        XCTAssertFalse(model.message?.contains("/private/var/") == true)
        LibraryStatusStore.shared.selectDevice(binding: nil)
    }
}

private struct StubInventoryQuery: DeviceInstalledAppQuerying {
    let results: [String: DeviceInstalledApplication?]

    func application(for identifier: String, request: DeviceConnectionRequest,
                     reporting: @escaping @Sendable (DeviceConnectionStage) -> Void) async throws -> DeviceInstalledApplication? {
        results[identifier] ?? nil
    }
}
