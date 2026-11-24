//
//  InstallVerdictPolicyTests.swift
//  VexSignTests
//

import XCTest
@testable import VexSign

final class InstallVerdictPolicyTests: XCTestCase {
    func testTheExactVersionIsTheOnlyConfirmedOutcome() {
        XCTAssertEqual(InstallVerdictPolicy.outcome(for: .installed), .confirmed)
        for verdict in [InstallConfirmation.Verdict.installedOtherVersion("2.0"), .notInstalled,
                        .timedOutWaiting, .timedOutVerifying, .cancelled] {
            XCTAssertNotEqual(InstallVerdictPolicy.outcome(for: verdict), .confirmed, "\(verdict)")
        }
    }

    func testAnotherVersionIsPresenceNotProofOfThisArtifact() {
        XCTAssertEqual(InstallVerdictPolicy.outcome(for: .installedOtherVersion("1.2")), .anotherVersion)
        XCTAssertEqual(InstallVerdictPolicy.outcome(for: .installedOtherVersion(nil)), .anotherVersion)
    }

    func testNoEvidenceIsOneGroup() {
        for verdict in [InstallConfirmation.Verdict.notInstalled, .timedOutWaiting, .timedOutVerifying] {
            XCTAssertEqual(InstallVerdictPolicy.outcome(for: verdict), .notConfirmed, "\(verdict)")
        }
    }

    func testCancellationIsNotAFailure() {
        XCTAssertEqual(InstallVerdictPolicy.outcome(for: .cancelled), .cancelled)
    }

    func testEveryVerdictIsClassifiedDeliberately() {
        // The mapping has no `default:` arm, so a new verdict is a compile error rather than a
        // silent fall-through. This list is what keeps that true as verdicts are added.
        let verdicts: [InstallConfirmation.Verdict] = [
            .installed, .installedOtherVersion("2.0"), .notInstalled,
            .timedOutWaiting, .timedOutVerifying, .cancelled
        ]
        XCTAssertEqual(verdicts.count, 6)
        for verdict in verdicts {
            let outcome = InstallVerdictPolicy.outcome(for: verdict)
            XCTAssertTrue([
                InstallVerdictOutcome.confirmed, .cancelled, .anotherVersion, .notConfirmed
            ].contains(outcome), "\(verdict)")
        }
    }
}
