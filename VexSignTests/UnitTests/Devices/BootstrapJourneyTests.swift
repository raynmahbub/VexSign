// Computer-free bootstrap journey tests. These exercise only the evidence rules;
// no pairing, signing, installation or device access is simulated here.
import Foundation
import IDeviceSwift
import XCTest
@testable import VexSign

final class BootstrapJourneyTests: XCTestCase {
    private let udid = "00008120-001A2B3C4D5E6F70"
    private let otherUDID = "00008130-001A2B3C4D5E6F71"
    private let fingerprint = String(repeating: "a", count: 64)
    private let digest = String(repeating: "b", count: 64)
    private let signer = String(repeating: "c", count: 64)

    private func journey(expectedUDID: String? = nil) -> BootstrapJourney {
        BootstrapJourney(expectedBundleIdentifier: "com.vexsign.app",
                         expectedVersion: "1.0",
                         expectedDeviceIdentifier: expectedUDID)
    }

    private func environment(_ route: BootstrapRoute = .onDeviceHost,
                             simulator: Bool = false) -> BootstrapEvent {
        .environment(route: route, simulator: simulator)
    }

    private func completeFirstFour(_ journey: inout BootstrapJourney,
                                   route: BootstrapRoute = .onDeviceHost,
                                   format: PairingRecordFormat = .remotePairing) {
        XCTAssertEqual(journey.record(environment(route)), .accepted(.environment))
        XCTAssertEqual(journey.record(.pairing(format: format, fingerprint: fingerprint)),
                       .accepted(.pairing))
        XCTAssertEqual(journey.record(.verified(deviceIdentifier: udid,
                                                productVersion: "27.0",
                                                pairingFingerprint: fingerprint)),
                       .accepted(.verification))
        XCTAssertEqual(journey.record(.authorized(kind: .importedCertificate,
                                                  teamIdentifier: "ABCDEFGHIJ")),
                       .accepted(.account))
    }

    // MARK: - Capability

    func testCapabilityUsesOneRouteSourceAndNeverPromisesComputerFreeOnOlderOS() {
        let classic = BootstrapCapability(osVersion: .init(major: 26, minor: 3),
                                          hostAvailable: true, isSimulator: false,
                                          pairedInstallationAccepted: false)
        XCTAssertEqual(classic.route, .pairingFileImport)
        XCTAssertFalse(classic.route.isComputerFree)
        XCTAssertFalse(classic.canStartComputerFreePairing)
        XCTAssertTrue(classic.blockers.contains(.pairingFileRequired))

        let modern = BootstrapCapability(osVersion: .init(major: 27, minor: 0),
                                         hostAvailable: true, isSimulator: false,
                                         pairedInstallationAccepted: true)
        XCTAssertEqual(modern.route, .onDeviceHost)
        XCTAssertTrue(modern.canStartComputerFreePairing)
        XCTAssertFalse(modern.blockers.contains(.installationBridgePending))

        let noHost = BootstrapCapability(osVersion: .init(major: 27, minor: 0),
                                         hostAvailable: false, isSimulator: false,
                                         pairedInstallationAccepted: true)
        XCTAssertEqual(noHost.route, .unavailable)
        XCTAssertTrue(noHost.blockers.contains(.hostUnavailable))

        let unknown = BootstrapCapability(osVersion: .init(major: 26, minor: 8),
                                          hostAvailable: true, isSimulator: false,
                                          pairedInstallationAccepted: true)
        XCTAssertEqual(unknown.route, .unavailable)
        XCTAssertTrue(unknown.blockers.contains(.unsupportedOS))

        let simulator = BootstrapCapability(osVersion: .init(major: 27, minor: 0),
                                            hostAvailable: true, isSimulator: true,
                                            pairedInstallationAccepted: true)
        XCTAssertEqual(simulator.route, .unavailable)
        XCTAssertTrue(simulator.blockers.contains(.simulator))
    }

    // MARK: - Full ladder

    func testFullJourneyRequiresDistinctEvidenceForEveryStep() {
        var journey = journey(expectedUDID: udid)
        XCTAssertEqual(journey.nextStep, .environment)
        XCTAssertFalse(journey.isComplete)

        completeFirstFour(&journey)
        XCTAssertEqual(journey.nextStep, .artifact)
        XCTAssertEqual(journey.record(.artifact(bundleIdentifier: "com.vexsign.app",
                                                version: "1.0", build: "42", sha256: digest)),
                       .accepted(.artifact))
        XCTAssertEqual(journey.record(.signed(bundleIdentifier: "com.vexsign.app",
                                              signerFingerprint: signer, sha256: digest)),
                       .accepted(.signing))
        XCTAssertEqual(journey.record(.installationRequested(bundleIdentifier: "com.vexsign.app",
                                                            sha256: digest)),
                       .accepted(.installation))
        XCTAssertFalse(journey.isComplete, "An accepted request is not an installed app")

        XCTAssertEqual(journey.record(.installationConfirmed(bundleIdentifier: "com.vexsign.app",
                                                             version: "1.0", build: "42",
                                                             sha256: digest, receipt: "task-17")),
                       .accepted(.confirmation))
        XCTAssertTrue(journey.isComplete)
        XCTAssertNil(journey.nextStep)
        XCTAssertTrue(journey.isComputerFree)
        XCTAssertEqual(journey.eventLog, BootstrapStep.allCases.map(\.rawValue))
        XCTAssertEqual(journey.evidence.receipt, "task-17")
    }

    func testPairingFileRouteCanCompleteWithoutClaimingComputerFree() {
        var journey = journey(expectedUDID: udid)
        completeFirstFour(&journey, route: .pairingFileImport, format: .combined)
        XCTAssertEqual(journey.nextStep, .artifact)
        XCTAssertFalse(journey.isComputerFree)
        XCTAssertEqual(journey.evidence.pairingFormat, .combined)
    }

    // MARK: - Rejections

    func testOutOfOrderEventsDoNotCompleteAStepOrStoreEvidence() {
        var journey = journey(expectedUDID: udid)
        XCTAssertEqual(journey.record(.pairing(format: .remotePairing, fingerprint: fingerprint)),
                       .rejected(.outOfOrder))
        XCTAssertTrue(journey.completed.isEmpty)
        XCTAssertNil(journey.evidence.pairingFingerprint)

        XCTAssertEqual(journey.record(environment()), .accepted(.environment))
        XCTAssertEqual(journey.record(.artifact(bundleIdentifier: "com.vexsign.app",
                                                version: "1.0", build: "42", sha256: digest)),
                       .rejected(.outOfOrder))
        XCTAssertEqual(journey.nextStep, .pairing)
        XCTAssertNil(journey.evidence.bundleIdentifier)
    }

    func testPairingFormatMustMatchTheDetectedRoute() {
        var journey = journey(expectedUDID: udid)
        XCTAssertEqual(journey.record(environment(.pairingFileImport)), .accepted(.environment))
        XCTAssertEqual(journey.record(.pairing(format: .remotePairing, fingerprint: fingerprint)),
                       .rejected(.wrongPairingFormat))
        XCTAssertEqual(journey.record(.pairing(format: .lockdown, fingerprint: fingerprint)),
                       .accepted(.pairing))
    }

    func testFingerprintAndTeamIdentifierAreValidated() {
        var journey = journey(expectedUDID: udid)
        XCTAssertEqual(journey.record(environment()), .accepted(.environment))
        XCTAssertEqual(journey.record(.pairing(format: .remotePairing, fingerprint: "short")),
                       .rejected(.invalidFingerprint))
        XCTAssertEqual(journey.record(.pairing(format: .remotePairing, fingerprint: fingerprint)),
                       .accepted(.pairing))
        XCTAssertEqual(journey.record(.verified(deviceIdentifier: udid,
                                                productVersion: "27.0",
                                                pairingFingerprint: String(repeating: "d", count: 64))),
                       .rejected(.pairingMismatch))
        XCTAssertEqual(journey.record(.verified(deviceIdentifier: udid,
                                                productVersion: "27.0",
                                                pairingFingerprint: fingerprint)),
                       .accepted(.verification))
        XCTAssertEqual(journey.record(.authorized(kind: .appleAccountPaid, teamIdentifier: "short")),
                       .rejected(.invalidTeamIdentifier))
        XCTAssertEqual(journey.record(.authorized(kind: .appleAccountPaid,
                                                  teamIdentifier: "ABCDEFGHIJ")),
                       .accepted(.account))
    }

    func testSelectedDeviceMustBeTheDeviceThatAnswered() {
        var journey = journey(expectedUDID: udid)
        XCTAssertEqual(journey.record(environment()), .accepted(.environment))
        XCTAssertEqual(journey.record(.pairing(format: .remotePairing, fingerprint: fingerprint)),
                       .accepted(.pairing))
        XCTAssertEqual(journey.record(.verified(deviceIdentifier: otherUDID,
                                                productVersion: "27.0",
                                                pairingFingerprint: fingerprint)),
                       .rejected(.deviceMismatch))
        XCTAssertNil(journey.evidence.deviceIdentifier)
        XCTAssertEqual(journey.record(.verified(deviceIdentifier: udid,
                                                productVersion: "27.0",
                                                pairingFingerprint: fingerprint)),
                       .accepted(.verification))
    }

    func testSimulatorCannotRecordAnEnvironment() {
        var journey = journey(expectedUDID: udid)
        XCTAssertEqual(journey.record(environment(.onDeviceHost, simulator: true)),
                       .rejected(.simulator))
        XCTAssertEqual(journey.record(environment(.unavailable)), .rejected(.unsupportedRoute))
        XCTAssertEqual(journey.nextStep, .environment)
    }

    // MARK: - Artifact and install evidence

    func testSigningAndInstallationMustUseTheExactSelectedArtifact() {
        var journey = journey(expectedUDID: udid)
        completeFirstFour(&journey)
        let wrongDigest = String(repeating: "e", count: 64)

        XCTAssertEqual(journey.record(.artifact(bundleIdentifier: "com.other.app",
                                                version: "1.0", build: "42", sha256: digest)),
                       .rejected(.invalidArtifact))
        XCTAssertEqual(journey.record(.artifact(bundleIdentifier: "com.vexsign.app",
                                                version: "2.0", build: "42", sha256: digest)),
                       .rejected(.invalidArtifact))
        XCTAssertEqual(journey.record(.artifact(bundleIdentifier: "com.vexsign.app",
                                                version: "1.0", build: "42", sha256: digest)),
                       .accepted(.artifact))
        XCTAssertEqual(journey.record(.signed(bundleIdentifier: "com.vexsign.app",
                                              signerFingerprint: signer, sha256: wrongDigest)),
                       .rejected(.artifactMismatch))
        XCTAssertEqual(journey.record(.signed(bundleIdentifier: "com.vexsign.app",
                                              signerFingerprint: signer, sha256: digest)),
                       .accepted(.signing))
        XCTAssertEqual(journey.record(.installationRequested(bundleIdentifier: "com.vexsign.app",
                                                            sha256: wrongDigest)),
                       .rejected(.artifactMismatch))
        XCTAssertEqual(journey.record(.installationRequested(bundleIdentifier: "com.vexsign.app",
                                                            sha256: digest)),
                       .accepted(.installation))
        XCTAssertEqual(journey.record(.installationConfirmed(bundleIdentifier: "com.vexsign.app",
                                                             version: "1.0", build: "42",
                                                             sha256: digest, receipt: "")),
                       .rejected(.invalidReceipt))
        XCTAssertEqual(journey.record(.installationConfirmed(bundleIdentifier: "com.vexsign.app",
                                                             version: "9.9", build: "42",
                                                             sha256: digest, receipt: "task-18")),
                       .rejected(.artifactMismatch))
        XCTAssertFalse(journey.isComplete)
        XCTAssertNil(journey.evidence.receipt)
    }

    func testResetReturnsToTheFirstStepWithoutKeepingEvidence() {
        var journey = journey(expectedUDID: udid)
        completeFirstFour(&journey)
        journey.reset()
        XCTAssertEqual(journey.nextStep, .environment)
        XCTAssertTrue(journey.completed.isEmpty)
        XCTAssertNil(journey.evidence.pairingFingerprint)
        XCTAssertTrue(journey.eventLog.isEmpty)
        XCTAssertNil(journey.lastRejection)
    }
}
