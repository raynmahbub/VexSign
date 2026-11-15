// Synthetic native-result validation only. No FFI/device or installation acceptance.
import Foundation
import XCTest
import os
#if canImport(DeviceFoundation)
@testable import DeviceFoundation
#else
@testable import IDeviceSwift
#endif

final class DeviceApplicationInventoryTests: XCTestCase {
    private let digest = String(repeating: "a", count: 64)
    private let epoch = Date(timeIntervalSince1970: 2_000_000)
    private var binding: DeviceSessionBinding {
        DeviceSessionBinding(deviceIdentifier: PairingRecordTestFixtures.device, pairingSHA256: digest)!
    }
    private func record(identifier: String = "com.example.app", version: String? = "1.2", build: String? = "7",
                        path: String = "/private/var/containers/Bundle/Application/TEST/App.app", clip: Bool = false,
                        name: String = "Synthetic App") -> DeviceApplicationInventory.Record {
        .init(bundleIdentifier: identifier, name: name, version: version, build: build, path: path, isAppClip: clip)
    }
    private func inventory(_ records: [DeviceApplicationInventory.Record]) throws -> DeviceApplicationInventory {
        try .validated(records, binding: binding, observedAt: epoch)
    }

    func testBindingNormalizesDeviceIdentifiersButScopesToBothDeviceAndRecord() throws {
        let lower = try XCTUnwrap(DeviceSessionBinding(deviceIdentifier: "  " + PairingRecordTestFixtures.device.lowercased() + "\n", pairingSHA256: digest))
        XCTAssertEqual(lower, binding)
        XCTAssertNotEqual(DeviceSessionBinding(deviceIdentifier: PairingRecordTestFixtures.otherDevice, pairingSHA256: digest), binding)
        XCTAssertNotEqual(DeviceSessionBinding(deviceIdentifier: PairingRecordTestFixtures.device, pairingSHA256: String(repeating: "b", count: 64)), binding)
    }

    func testHostUUIDAndMalformedDigestsCannotBeDeviceBindings() {
        XCTAssertNil(DeviceSessionBinding(deviceIdentifier: PairingRecordTestFixtures.host, pairingSHA256: digest))
        for invalid in ["", String(repeating: "a", count: 63), String(repeating: "A", count: 64), "sha256:" + digest] {
            XCTAssertNil(DeviceSessionBinding(deviceIdentifier: PairingRecordTestFixtures.device, pairingSHA256: invalid))
        }
    }

    func testBindingEncodingAndDescriptionsContainNoRawDeviceOrRecord() throws {
        let encoded = try JSONEncoder().encode(binding)
        let decoded = try JSONDecoder().decode(DeviceSessionBinding.self, from: encoded)
        XCTAssertEqual(decoded, binding)
        let text = String(decoding: encoded, as: UTF8.self) + String(describing: binding) + String(reflecting: binding)
        XCTAssertFalse(text.contains(PairingRecordTestFixtures.device))
        XCTAssertFalse(text.contains(digest))
    }

    func testPositiveMetadataRetainsExactVersionsDateAndDeviceBinding() throws {
        let apps = try inventory([record()])
        let app = try XCTUnwrap(apps.application(for: "com.example.app"))
        XCTAssertEqual(app.version, "1.2")
        XCTAssertEqual(app.build, "7")
        XCTAssertEqual(app.binding, binding)
        XCTAssertEqual(app.observedAt, epoch)
        XCTAssertEqual(app.bundlePath, "/private/var/containers/Bundle/Application/TEST/App.app")
        XCTAssertFalse(String(reflecting: app).contains(app.bundlePath))
    }

    func testMissingVersionsStayMissingRatherThanCopiedFromAnExpectation() throws {
        let app = try XCTUnwrap(inventory([record(version: nil, build: nil)]).application(for: "com.example.app"))
        XCTAssertNil(app.version)
        XCTAssertNil(app.build)
    }

    func testEmptyOrOmittedResultsAreUnknownAndDoNotFabricateAnAbsentRecord() throws {
        XCTAssertNil(try inventory([]).application(for: "com.example.app"))
        XCTAssertNil(try inventory([record(identifier: "com.example.other")]).application(for: "com.example.app"))
    }

    func testIdentifiersAreExactAndNeverTrimmedCaseFoldedOrSubstituted() throws {
        let apps = try inventory([record()])
        for invalid in ["com.example.App", " com.example.app", "com.example.app\n", "com..app", ".com.app", "com.app.", "other"] {
            XCTAssertNil(apps.application(for: invalid))
        }
    }

    func testDuplicateIdentifiersRefuseTheEntireAmbiguousNativeResult() {
        XCTAssertThrowsError(try inventory([record(), record(build: "8")]))
    }

    func testClipsAndExtensionsNeverStandInForAFullInstalledApp() throws {
        XCTAssertNil(try inventory([record(clip: true)]).application(for: "com.example.app"))
        XCTAssertNil(try inventory([record(path: "/Applications/App.appex")]).application(for: "com.example.app"))
    }

    func testPathsCannotBeURLsRelativeTraversalOrControlText() {
        for path in ["App.app", "file:///Applications/App.app", "/Applications/../App.app", "/Applications/./App.app",
                     "/Applications//App.app", "/Applications/App.app/", "/Applications/App\u{0}.app", "/App\\Other.app"] {
            XCTAssertThrowsError(try inventory([record(path: path)]), path)
        }
    }

    func testMalformedVersionBuildAndControlNamesFailClosed() {
        for version in ["", "v1.2", " 1.2", "1.2\n", String(repeating: "1", count: 65)] {
            XCTAssertThrowsError(try inventory([record(version: version)]))
            XCTAssertThrowsError(try inventory([record(build: version)]))
        }
        XCTAssertThrowsError(try inventory([record(name: "unsafe\nname")]))
    }

    func testResultLimitAndNonfiniteObservationTimesRefusePartialInventory() {
        XCTAssertThrowsError(try inventory(Array(repeating: record(), count: DeviceApplicationInventory.maximumEntries + 1)))
        XCTAssertThrowsError(try DeviceApplicationInventory.validated([], binding: binding, observedAt: Date(timeIntervalSince1970: .nan)))
    }

    func testInstallationTargetRequiresExactMetadataAndAnUnprefixedDigest() {
        XCTAssertNotNil(DeviceInstallationTarget(bundleIdentifier: "com.example.app", version: "1.2", build: "7", packageSHA256: digest, authorizationExpiresAt: epoch.addingTimeInterval(60), verifiedDeviceOS: "18.0"))
        XCTAssertNil(DeviceInstallationTarget(bundleIdentifier: "com.example.app", version: "", build: "7", packageSHA256: digest, authorizationExpiresAt: epoch.addingTimeInterval(60), verifiedDeviceOS: "18.0"))
        XCTAssertNil(DeviceInstallationTarget(bundleIdentifier: "com.example.app", version: "1.2", build: "", packageSHA256: digest, authorizationExpiresAt: epoch.addingTimeInterval(60), verifiedDeviceOS: "18.0"))
        XCTAssertNil(DeviceInstallationTarget(bundleIdentifier: "com.example.app", version: "1.2", build: "7", packageSHA256: "sha256:" + digest, authorizationExpiresAt: epoch.addingTimeInterval(60), verifiedDeviceOS: "18.0"))
    }

    func testFrozenConnectionRequestCarriesRecordScopedBinding() throws {
        let request = DeviceConnectionRequest(pairingFile: URL(fileURLWithPath: "/synthetic/pairing.plist"),
            expectedDeviceIdentifier: PairingRecordTestFixtures.device, protocolConsent: true, expectedPairingSHA256: digest)
        XCTAssertEqual(request.binding, binding)
        XCTAssertEqual(request.expectedPairingSHA256, digest)
        let initialQuery = DeviceConnectionRequest(pairingFile: request.pairingFile,
            expectedDeviceIdentifier: request.expectedDeviceIdentifier, protocolConsent: true)
        XCTAssertNil(initialQuery.binding)
    }

    func testExpiredAuthorizationOrAnOSChangeAfterPreparationCannotBeSubmitted() throws {
        let target = try XCTUnwrap(DeviceInstallationTarget(bundleIdentifier: "com.example.app", version: "1.2", build: "7",
            packageSHA256: digest, authorizationExpiresAt: epoch.addingTimeInterval(1), verifiedDeviceOS: "18.0"))
        XCTAssertTrue(target.permitsSubmission(deviceOS: "18.0", at: epoch))
        XCTAssertFalse(target.permitsSubmission(deviceOS: "18.0", at: epoch.addingTimeInterval(1)))
        XCTAssertFalse(target.permitsSubmission(deviceOS: "18.1", at: epoch))
        XCTAssertFalse(target.permitsSubmission(deviceOS: "18.0", at: Date(timeIntervalSince1970: .nan)))
    }

    func testStoppingPreparationPreventsSubmissionEvenBeforeWaiterCancellationArrives() {
        let control = DeviceInstallationControl()
        XCTAssertNil(control.stopBeforeSubmission())
        XCTAssertThrowsError(try control.beginSubmission(at: epoch, cancellation: Progress(totalUnitCount: 1)))
        XCTAssertNil(control.submittedAt)
        XCTAssertNil(control.stopBeforeSubmission())
    }

    func testStoppingAfterSubmissionIsMonitoringOnlyAndSubmissionCannotBeRepeated() throws {
        let control = DeviceInstallationControl()
        let cancellation = Progress(totalUnitCount: 1)
        try control.beginSubmission(at: epoch, cancellation: cancellation)
        cancellation.cancel()
        XCTAssertEqual(control.stopBeforeSubmission(), epoch)
        XCTAssertEqual(control.submittedAt, epoch)
        XCTAssertThrowsError(try control.beginSubmission(at: epoch, cancellation: Progress(totalUnitCount: 1)))
    }

    func testAnAlreadyCancelledWorkerCannotCrossTheCommandBoundary() {
        let control = DeviceInstallationControl()
        let cancellation = Progress(totalUnitCount: 1)
        cancellation.cancel()
        XCTAssertThrowsError(try control.beginSubmission(at: epoch, cancellation: cancellation))
        XCTAssertNil(control.submittedAt)
    }

    func testStopAndSubmissionHaveOneAtomicOrderUnderConcurrentCalls() {
        let date = epoch
        for _ in 0..<100 {
            let control = DeviceInstallationControl()
            let result = OSAllocatedUnfairLock(initialState: (submitted: false, stoppedBeforeCommand: false))
            DispatchQueue.concurrentPerform(iterations: 2) { index in
                if index == 0 {
                    let noHandoff = control.stopBeforeSubmission() == nil
                    result.withLock { $0.stoppedBeforeCommand = noHandoff }
                } else {
                    do {
                        try control.beginSubmission(at: date, cancellation: Progress(totalUnitCount: 1))
                        result.withLock { $0.submitted = true }
                    } catch {
                        // A Stop that wins admission must prevent the command.
                    }
                }
            }
            let outcome = result.withLock { $0 }
            XCTAssertNotEqual(outcome.submitted, outcome.stoppedBeforeCommand)
            XCTAssertEqual(outcome.submitted, control.submittedAt != nil)
        }
    }
}
