// Paired-installation evidence tests. Pure ledger only: no pairing,
// signing, submission, device query, install or launch is simulated here.
import Foundation
import XCTest
@testable import IDeviceSwift
@testable import VexSign

final class PairedInstallationJourneyTests: XCTestCase {
    private let device = String(repeating: "A", count: 40)
    private let digest = String(repeating: "b", count: 64)
    private let signer = String(repeating: "c", count: 64)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func journey() -> PairedInstallationJourney {
        PairedInstallationJourney(expectedDeviceIdentifier: device)
    }

    @discardableResult
    private func admitRouteAndPairing(_ journey: inout PairedInstallationJourney,
                                      format: PairingRecordFormat = .combined,
                                      inventoryAccepted: Bool = true) -> Bool {
        if case .failure = journey.record(.route(.onDeviceHostPairing,
                                                  inventoryAccepted: inventoryAccepted)) { return false }
        if case .failure = journey.record(.pairing(format: format, fingerprint: digest)) { return false }
        return true
    }

    private func completeLadder(_ journey: inout PairedInstallationJourney) {
        XCTAssertTrue(admitRouteAndPairing(&journey))
        XCTAssertSuccess(journey.record(.device(identifier: device, productVersion: "27.0",
                                               pairingFingerprint: digest)))
        XCTAssertSuccess(journey.record(.artifact(bundleIdentifier: "com.example.app", version: "1.0",
                                                 build: "1", sha256: digest)))
        XCTAssertSuccess(journey.record(.signature(bundleIdentifier: "com.example.app",
            signerFingerprint: signer, sha256: digest,
            authorizationExpiresAt: now.addingTimeInterval(86_400), at: now)))
        XCTAssertSuccess(journey.record(.submission(bundleIdentifier: "com.example.app", sha256: digest,
            receipt: "submission-1", at: now.addingTimeInterval(10))))
        XCTAssertSuccess(journey.record(.confirmation(bundleIdentifier: "com.example.app", version: "1.0",
            build: "1", sha256: digest, receipt: "confirmed-1", at: now.addingTimeInterval(60))))
        XCTAssertSuccess(journey.record(.launch(bundleIdentifier: "com.example.app", version: "1.0")))
    }

    private func XCTAssertSuccess(_ result: Result<PairedInstallationStep, PairedInstallationRejection>,
                                  file: StaticString = #filePath, line: UInt = #line) {
        guard case .success = result else {
            XCTFail("expected accepted step, got \(String(describing: result))", file: file, line: line)
            return
        }
    }

    func testBridgeGateIsFailClosed() {
        var journey = journey()
        XCTAssertTrue(admitRouteAndPairing(&journey, inventoryAccepted: false))
        XCTAssertEqual(journey.lastRejection, .routeBlocked)
        XCTAssertEqual(journey.nextStep, .route)
        XCTAssertFalse(journey.isComplete)
        XCTAssertNil(journey.evidence.pairingFingerprint)
    }

    func testUnsupportedRoutesAreRefused() {
        for route in [DevicePairingRoute.unsupported, .unknownOS, .importedRemoteRequired,
                      .hostDependencyRequired] {
            var journey = journey()
            if case .failure(let reason) = journey.record(.route(route, inventoryAccepted: true)) {
                XCTAssertEqual(reason, .routeBlocked)
            } else {
                XCTFail("route \(route) should be refused")
            }
        }
    }

    func testPairingFormatMustMatchRoute() {
        var onDevice = journey()
        XCTAssertTrue(admitRouteAndPairing(&onDevice, format: .lockdown))
        XCTAssertEqual(onDevice.lastRejection, .wrongPairingFormat)

        var classic = journey()
        XCTAssertSuccess(classic.record(.route(.importedClassic, inventoryAccepted: true)))
        if case .failure(let reason) = classic.record(.pairing(format: .remotePairing, fingerprint: digest)) {
            XCTAssertEqual(reason, .wrongPairingFormat)
        } else {
            XCTFail("remote-only record must not authorize the classic route")
        }
    }

    func testFullLadderIsCompleteOnlyAfterLaunch() {
        var journey = journey()
        XCTAssertFalse(journey.hasSubmission)
        XCTAssertFalse(journey.hasConfirmedInstallation)
        admitRouteAndPairing(&journey)
        XCTAssertSuccess(journey.record(.device(identifier: device, productVersion: "27.0",
                                               pairingFingerprint: digest)))
        XCTAssertSuccess(journey.record(.artifact(bundleIdentifier: "com.example.app", version: "1.0",
                                                 build: "1", sha256: digest)))
        XCTAssertSuccess(journey.record(.signature(bundleIdentifier: "com.example.app",
            signerFingerprint: signer, sha256: digest,
            authorizationExpiresAt: now.addingTimeInterval(86_400), at: now)))
        XCTAssertSuccess(journey.record(.submission(bundleIdentifier: "com.example.app", sha256: digest,
            receipt: "submission-1", at: now.addingTimeInterval(10))))
        XCTAssertTrue(journey.hasSubmission)
        XCTAssertFalse(journey.hasConfirmedInstallation)
        XCTAssertFalse(journey.isComplete)
        XCTAssertSuccess(journey.record(.confirmation(bundleIdentifier: "com.example.app", version: "1.0",
            build: "1", sha256: digest, receipt: "confirmed-1", at: now.addingTimeInterval(60))))
        XCTAssertTrue(journey.hasConfirmedInstallation)
        XCTAssertEqual(journey.nextStep, .launch)
        XCTAssertFalse(journey.isComplete)
        XCTAssertSuccess(journey.record(.launch(bundleIdentifier: "com.example.app", version: "1.0")))
        XCTAssertTrue(journey.isComplete)
    }

    func testCompleteJourneyAndReset() {
        var journey = journey()
        admitRouteAndPairing(&journey)
        XCTAssertSuccess(journey.record(.device(identifier: device, productVersion: "27.0",
                                               pairingFingerprint: digest)))
        XCTAssertSuccess(journey.record(.artifact(bundleIdentifier: "com.example.app", version: "1.0",
                                                 build: "1", sha256: digest)))
        XCTAssertSuccess(journey.record(.signature(bundleIdentifier: "com.example.app",
            signerFingerprint: signer, sha256: digest,
            authorizationExpiresAt: now.addingTimeInterval(86_400), at: now)))
        XCTAssertSuccess(journey.record(.submission(bundleIdentifier: "com.example.app", sha256: digest,
            receipt: "submission-1", at: now.addingTimeInterval(10))))
        XCTAssertSuccess(journey.record(.confirmation(bundleIdentifier: "com.example.app", version: "1.0",
            build: "1", sha256: digest, receipt: "confirmed-1", at: now.addingTimeInterval(60))))
        XCTAssertSuccess(journey.record(.launch(bundleIdentifier: "com.example.app", version: "1.0")))
        XCTAssertTrue(journey.isComplete)
        XCTAssertNil(journey.nextStep)
        XCTAssertEqual(journey.eventLog, ["route", "pairing", "device", "artifact", "signature",
                                          "submission", "confirmation", "launch"])
        journey.reset()
        XCTAssertFalse(journey.isComplete)
        XCTAssertEqual(journey.nextStep, .route)
        XCTAssertTrue(journey.eventLog.isEmpty)
    }

    func testDeviceAndArtifactMustMatchTheSelectedTarget() {
        var wrongDevice = journey()
        XCTAssertTrue(admitRouteAndPairing(&wrongDevice))
        if case .failure(let reason) = wrongDevice.record(.device(identifier: String(repeating: "D", count: 40),
            productVersion: "27.0", pairingFingerprint: digest)) {
            XCTAssertEqual(reason, .wrongDevice)
        } else { XCTFail("another device must be refused") }

        var wrongFingerprint = journey()
        XCTAssertTrue(admitRouteAndPairing(&wrongFingerprint))
        if case .failure(let reason) = wrongFingerprint.record(.device(identifier: device,
            productVersion: "27.0", pairingFingerprint: String(repeating: "e", count: 64))) {
            XCTAssertEqual(reason, .pairingMismatch)
        } else { XCTFail("a different pairing record must be refused") }

        var invalidArtifact = journey()
        XCTAssertTrue(admitRouteAndPairing(&invalidArtifact))
        XCTAssertSuccess(invalidArtifact.record(.device(identifier: device, productVersion: "27.0",
            pairingFingerprint: digest)))
        if case .failure(let reason) = invalidArtifact.record(.artifact(bundleIdentifier: "com.example.app",
            version: "1.0", build: "1", sha256: "short")) {
            XCTAssertEqual(reason, .invalidArtifact)
        } else { XCTFail("a non-SHA-256 artifact digest must be refused") }
    }

    func testSubmissionAndConfirmationRemainDistinctOutcomes() {
        var journey = journey()
        admitRouteAndPairing(&journey)
        XCTAssertSuccess(journey.record(.device(identifier: device, productVersion: "27.0",
                                               pairingFingerprint: digest)))
        XCTAssertSuccess(journey.record(.artifact(bundleIdentifier: "com.example.app", version: "1.0",
                                                 build: "1", sha256: digest)))
        XCTAssertSuccess(journey.record(.signature(bundleIdentifier: "com.example.app",
            signerFingerprint: signer, sha256: digest,
            authorizationExpiresAt: now.addingTimeInterval(86_400), at: now)))

        if case .failure(let reason) = journey.record(.confirmation(bundleIdentifier: "com.example.app",
            version: "1.0", build: "1", sha256: digest, receipt: "confirmed-1",
            at: now.addingTimeInterval(60))) {
            XCTAssertEqual(reason, .confirmationBeforeSubmission)
        } else { XCTFail("confirmation before a submission is not evidence") }

        XCTAssertSuccess(journey.record(.submission(bundleIdentifier: "com.example.app", sha256: digest,
            receipt: "submission-1", at: now.addingTimeInterval(10))))
        if case .failure(let reason) = journey.record(.confirmation(bundleIdentifier: "com.example.app",
            version: "2.0", build: "2", sha256: digest, receipt: "confirmed-1",
            at: now.addingTimeInterval(60))) {
            XCTAssertEqual(reason, .artifactMismatch)
        } else { XCTFail("another version is not this artifact") }

        if case .failure(let reason) = journey.record(.confirmation(bundleIdentifier: "com.example.app",
            version: "1.0", build: "1", sha256: digest, receipt: "submission-1",
            at: now.addingTimeInterval(60))) {
            XCTAssertEqual(reason, .invalidReceipt)
        } else { XCTFail("an acknowledgement is not installation evidence") }
    }

    func testExpiredAuthorizationIsRefusedAndLaunchMustMatchConfirmation() {
        var expired = journey()
        XCTAssertTrue(admitRouteAndPairing(&expired))
        XCTAssertSuccess(expired.record(.device(identifier: device, productVersion: "27.0",
            pairingFingerprint: digest)))
        XCTAssertSuccess(expired.record(.artifact(bundleIdentifier: "com.example.app", version: "1.0",
            build: "1", sha256: digest)))
        if case .failure(let reason) = expired.record(.signature(bundleIdentifier: "com.example.app",
            signerFingerprint: signer, sha256: digest,
            authorizationExpiresAt: now.addingTimeInterval(-1), at: now)) {
            XCTAssertEqual(reason, .expiredAuthorization)
        } else { XCTFail("an expired profile cannot authorize an install") }

        var launched = journey()
        completeLadder(&launched)
        XCTAssertTrue(launched.isComplete)
        var wrongLaunch = journey()
        admitRouteAndPairing(&wrongLaunch)
        XCTAssertSuccess(wrongLaunch.record(.device(identifier: device, productVersion: "27.0",
            pairingFingerprint: digest)))
        XCTAssertSuccess(wrongLaunch.record(.artifact(bundleIdentifier: "com.example.app", version: "1.0",
            build: "1", sha256: digest)))
        XCTAssertSuccess(wrongLaunch.record(.signature(bundleIdentifier: "com.example.app",
            signerFingerprint: signer, sha256: digest,
            authorizationExpiresAt: now.addingTimeInterval(86_400), at: now)))
        XCTAssertSuccess(wrongLaunch.record(.submission(bundleIdentifier: "com.example.app", sha256: digest,
            receipt: "submission-1", at: now.addingTimeInterval(10))))
        XCTAssertSuccess(wrongLaunch.record(.confirmation(bundleIdentifier: "com.example.app", version: "1.0",
            build: "1", sha256: digest, receipt: "confirmed-1", at: now.addingTimeInterval(60))))
        if case .failure(let reason) = wrongLaunch.record(.launch(bundleIdentifier: "com.example.app",
            version: "2.0")) {
            XCTAssertEqual(reason, .launchMismatch)
        } else { XCTFail("another version was not launched") }
    }

    func testEveryRefusalCarriesAnActionableSentence() {
        for reason in PairedInstallationRejection.allCases {
            let message = reason.errorDescription ?? ""
            XCTAssertFalse(message.isEmpty)
            XCTAssertTrue(message.hasSuffix("."), message)
        }
    }
}
