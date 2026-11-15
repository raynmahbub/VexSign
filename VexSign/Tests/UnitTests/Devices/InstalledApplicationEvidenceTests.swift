// Synthetic state/receipt tests, never physical or Apple trust evidence.
import Foundation
import XCTest
import IDeviceSwift
@testable import VexSign

enum InstallationEvidenceTestFixtures {
    static let device = "00008120-001A2B3C4D5E6F70"
    static let otherDevice = "00008120-101A2B3C4D5E6F70"
    static let digest = String(repeating: "a", count: 64)
    static let binding = DeviceSessionBinding(deviceIdentifier: device, pairingSHA256: digest)!
    static let otherBinding = DeviceSessionBinding(deviceIdentifier: otherDevice, pairingSHA256: digest)!
    static let epoch = Date(timeIntervalSince1970: 2_000_000)

    static func application(identifier: String = "com.example.app", version: String = "1.2", build: String = "7",
                            binding: DeviceSessionBinding = InstallationEvidenceTestFixtures.binding, at date: Date = Date()) -> InstalledApp {
        let evidence = InstalledApplicationEvidence(bundleIdentifier: identifier, version: version, build: build,
            deviceBinding: binding, observedAt: date)!
        return InstalledApp(bundleIdentifier: identifier, isInstalled: true, version: version, build: build, evidence: evidence)
    }

    static func context() -> TaskContext {
        var context = TaskContext()
        context.installationMethod = "paired-device"
        context.expectedBundleIdentifier = "com.example.app"
        context.appVersion = "1.2"
        context.appBuild = "7"
        context.confirmationReason = "device-confirmed-installed"
        context.handoffAt = epoch
        context.nativeAcknowledgedAt = epoch.addingTimeInterval(1)
        context.expectedDeviceBinding = binding
        context.installationPackageSHA256 = digest
        context.installedApplicationEvidence = application(at: epoch.addingTimeInterval(2)).evidence
        return context
    }
}

final class InstalledApplicationEvidenceTests: XCTestCase {
    private typealias Fixture = InstallationEvidenceTestFixtures

    private func confirmation() -> InstallConfirmation {
        var engine = InstallConfirmation(expectation: .init(bundleIdentifier: "com.example.app", version: "1.2", build: "7",
            deviceBinding: Fixture.binding, evidenceNotBefore: Fixture.epoch))
        _ = engine.beginVerifying(at: Fixture.epoch)
        return engine
    }

    func testExactFreshReadingConfirmsAndRetainsTheActualObservation() {
        var engine = confirmation()
        let reading = Fixture.application(at: Fixture.epoch.addingTimeInterval(1))
        XCTAssertEqual(engine.record(probe: reading, at: Fixture.epoch.addingTimeInterval(2)), .finished(.installed))
        XCTAssertEqual(engine.confirmedApplication, reading)
    }

    func testCrossDeviceOrReplacedPairingRecordCannotConfirm() throws {
        let replaced = try XCTUnwrap(DeviceSessionBinding(deviceIdentifier: Fixture.device, pairingSHA256: String(repeating: "b", count: 64)))
        for binding in [Fixture.otherBinding, replaced] {
            var engine = confirmation()
            XCTAssertEqual(engine.record(probe: Fixture.application(binding: binding, at: Fixture.epoch),
                at: Fixture.epoch.addingTimeInterval(30)), .finished(.timedOutVerifying))
            XCTAssertNil(engine.confirmedApplication)
        }
    }

    func testStaleOrFutureObservationsCannotConfirm() {
        for date in [Fixture.epoch.addingTimeInterval(-1), Fixture.epoch.addingTimeInterval(60)] {
            var engine = confirmation()
            XCTAssertEqual(engine.record(probe: Fixture.application(at: date), at: Fixture.epoch.addingTimeInterval(30)),
                           .finished(.timedOutVerifying))
        }
    }

    func testPrivateOrUnboundMetadataCannotConfirmEvenIfEveryVersionStringMatches() {
        var engine = confirmation()
        let unbound = InstalledApp(bundleIdentifier: "com.example.app", isInstalled: true, version: "1.2", build: "7")
        XCTAssertEqual(engine.record(probe: unbound, at: Fixture.epoch.addingTimeInterval(30)), .finished(.timedOutVerifying))
        XCTAssertNil(engine.confirmedApplication)
    }

    func testNoReconstructionFromMissingOrWrongBuildMetadata() {
        for reading in [InstalledApp(bundleIdentifier: "com.example.app", isInstalled: true, version: "1.2"),
                        Fixture.application(build: "8", at: Fixture.epoch)] {
            var engine = confirmation()
            XCTAssertFalse(engine.record(probe: reading, at: Fixture.epoch.addingTimeInterval(120)).verdict?.provesInstalled ?? false)
            XCTAssertNil(engine.confirmedApplication)
        }
    }

    func testLibraryDerivationChecksBuildAndDeviceInsteadOfVersionOnly() {
        let reading = Fixture.application(at: Fixture.epoch)
        XCTAssertEqual(InstalledState.derive(from: reading, expecting: "1.2", build: "7", binding: Fixture.binding), .installed)
        XCTAssertEqual(InstalledState.derive(from: reading, expecting: "1.2", build: "8", binding: Fixture.binding), .unknown)
        XCTAssertEqual(InstalledState.derive(from: reading, expecting: "1.2", build: "7", binding: Fixture.otherBinding), .unknown)
    }

    func testDatedContextRequiresAcknowledgementDigestAndExpectedBinding() {
        let valid = Fixture.context()
        let after = Fixture.epoch.addingTimeInterval(3)
        XCTAssertTrue(valid.hasConfirmedInstallation(notAfter: after))
        var missing = valid
        missing.nativeAcknowledgedAt = nil
        XCTAssertFalse(missing.hasConfirmedInstallation(notAfter: after))
        missing = valid; missing.expectedDeviceBinding = Fixture.otherBinding
        XCTAssertFalse(missing.hasConfirmedInstallation(notAfter: after))
        missing = valid; missing.installationPackageSHA256 = nil
        XCTAssertFalse(missing.hasConfirmedInstallation(notAfter: after))
        missing = valid; missing.appBuild = "8"
        XCTAssertFalse(missing.hasConfirmedInstallation(notAfter: after))
    }

    func testAnObservationBeforeTheAcknowledgementCannotPromoteHistory() {
        var context = Fixture.context()
        context.nativeAcknowledgedAt = Fixture.epoch.addingTimeInterval(3)
        XCTAssertFalse(context.hasConfirmedInstallation(notAfter: Fixture.epoch.addingTimeInterval(4)))
    }

    func testReceiptRoundTripRetainsOnlyAStructurallyCompleteDatedResult() throws {
        let task = UnifiedTask(kind: .install, title: "Synthetic", phase: .completed)
        task.createdAt = Fixture.epoch
        task.updatedAt = Fixture.epoch.addingTimeInterval(3)
        task.context = Fixture.context()
        let data = try JSONEncoder().encode(task.snapshot)
        let restored = UnifiedTask.from(try JSONDecoder().decode(UnifiedTask.Snapshot.self, from: data))
        XCTAssertEqual(restored.phase, .completed)
        XCTAssertEqual(restored.context?.installedApplicationEvidence, task.context?.installedApplicationEvidence)
        XCTAssertEqual(TaskReceipt.evidence(for: restored).confirmation, .confirmed)
        let report = TaskReceipt.report(for: restored)
        XCTAssertTrue(report.contains("Observed installed version/build: 1.2 (7)"))
        XCTAssertFalse(report.contains(Fixture.device))
        XCTAssertFalse(report.contains("com.example.app"))
        XCTAssertFalse(report.contains(Fixture.binding.sha256))
        // This remains a dated local observation, never a current Library badge.
        XCTAssertTrue(report.contains("Observed at:"))
    }

    func testReasonStringAloneCannotPromoteReceiptOrHistory() {
        let task = UnifiedTask(kind: .install, title: "Legacy", phase: .completed)
        task.context?.installationMethod = "paired-device"
        task.context?.confirmationReason = "device-confirmed-installed"
        XCTAssertEqual(TaskReceipt.evidence(for: task).confirmation, .unavailable)
        XCTAssertEqual(TaskReceipt.evidence(for: task).retrySafety, .checkDeviceFirst)
        XCTAssertFalse(TaskReceipt.report(for: task).contains("Result evidence: device-confirmed-installed"))
        XCTAssertEqual(UnifiedTask.from(task.snapshot).phase, .unconfirmed)
    }

    func testMalformedOptionalProofCannotDiscardUnrelatedTaskMetadata() throws {
        let context = try JSONDecoder().decode(TaskContext.self, from: Data(#"{"appVersion":"1.2","installedApplicationEvidence":"corrupt","expectedDeviceBinding":12,"nativeAcknowledgedAt":{},"installationPackageSHA256":false}"#.utf8))
        XCTAssertEqual(context.appVersion, "1.2")
        XCTAssertNil(context.installedApplicationEvidence)
        XCTAssertNil(context.expectedDeviceBinding)
        XCTAssertFalse(context.hasConfirmedInstallation(notAfter: Date()))
    }

    @MainActor
    func testLibraryRejectsCrossDeviceAndVersionOnlyConfirmationAndTargetChangesClearCache() {
        let store = LibraryStatusStore(probe: UnavailableInstallationProbe(), readGuest: { _ in .unavailable }, readSignature: { _ in .noCodeSignature })
        var request = LibraryStatusStore.Request(uuid: "row", bundleIdentifier: "com.example.app", expectedVersion: "1.2", bundleURL: nil, isSigned: true)
        request.expectedBuild = "7"
        store.request(request)
        store.recordInstalledApplicationObservation(InstalledApp(bundleIdentifier: "com.example.app", isInstalled: true, version: "1.2", build: "7"))
        XCTAssertNotEqual(store.statuses["row"]?.installed, .installed)
        store.selectDevice(binding: Fixture.binding)
        store.recordInstalledApplicationObservation(Fixture.application(binding: Fixture.otherBinding))
        XCTAssertNotEqual(store.statuses["row"]?.installed, .installed)
        store.recordInstalledApplicationObservation(Fixture.application())
        XCTAssertEqual(store.statuses["row"]?.installed, .installed)
        store.selectDevice(binding: Fixture.otherBinding)
        XCTAssertNotEqual(store.statuses["row"]?.installed, .installed)
        store.selectDevice(binding: nil)
        store.recordInstalledApplicationObservation(Fixture.application())
        XCTAssertNotEqual(store.statuses["row"]?.installed, .installed)
    }

    func testMalformedDecodedSchemaSourceAndDatesCannotBecomeEvidence() throws {
        let bytes = try JSONEncoder().encode(Fixture.application(at: Fixture.epoch).evidence)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let invalid: [(String, Any)] = [("schema", 2), ("source", "private-registry"),
                                        ("version", "1.2\n"), ("build", ""), ("observedAt", 1.0e100)]
        for (key, value) in invalid {
            var json = original; json[key] = value
            let decoded = try JSONDecoder().decode(InstalledApplicationEvidence.self, from: JSONSerialization.data(withJSONObject: json))
            XCTAssertFalse(decoded.isWellFormed, key)
        }
    }

    func testBoundPositiveEvidenceCannotBeTurnedIntoAnAuthoritativeNegative() {
        let observed = Fixture.application(at: Fixture.epoch)
        let contradictory = InstalledApp(bundleIdentifier: observed.bundleIdentifier, isInstalled: false,
            version: observed.version, build: observed.build, evidence: observed.evidence)
        XCTAssertEqual(InstalledState.derive(from: contradictory, expecting: "1.2", build: "7", binding: Fixture.binding), .unknown)
        XCTAssertEqual(InstalledState.derive(from: observed, expecting: "1.2", binding: Fixture.binding), .unknown)
    }

    func testPairedPollingBudgetAllowsAFreshNativeHandshakeWithoutUnboundedAttempts() {
        let policy = InstallVerificationPolicy.pairedDevice
        XCTAssertEqual(policy.probeTimeout(forAttempt: 1), 30)
        XCTAssertEqual(policy.probeTimeout(forAttempt: 1_000), 30)
        XCTAssertNotNil(policy.maximumAttempts(within: 120))
        XCTAssertGreaterThan(policy.probeTimeout(forAttempt: 1), InstallVerificationPolicy.standard.probeTimeout(forAttempt: 1))
    }

    func testLostCommandResponseIsUnknownNotAnAcknowledgedOrFailedInstallation() {
        let summary = InstallEvidenceSummary.resolve(method: "paired-device", reason: "paired-command-outcome-unknown", handedOff: true)
        XCTAssertEqual(summary.confirmation, .unavailable)
        XCTAssertEqual(summary.handoff, .recorded)
        XCTAssertEqual(summary.verification, .unavailable)
        XCTAssertEqual(summary.retrySafety, .checkDeviceFirst)
    }

    func testAsyncProbeOverrideIsDynamicallySelectedThroughTheProtocol() async {
        let expected = Fixture.application(at: Fixture.epoch)
        let probe: InstalledAppProbing = AsyncOnlyProbe(reading: expected)
        let reading = await probe.installedAppWithTimeout(for: "com.example.app", timeout: 1)
        XCTAssertEqual(reading, expected)
    }
}

private struct AsyncOnlyProbe: InstalledAppProbing {
    let reading: InstalledApp
    func installedApp(for bundleIdentifier: String) -> InstalledApp? { nil }
    func installedAppWithTimeout(for bundleIdentifier: String, timeout: TimeInterval) async -> InstalledApp? {
        bundleIdentifier == reading.bundleIdentifier ? reading : nil
    }
}
