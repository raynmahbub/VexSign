//
//  SigningMethodAvailabilityTests.swift
//  VexSignTests
//
//  The free-account caveat is the one sentence a user reads before choosing that method, and it
//  used to describe a defect that does not exist: it said provisioning was "not yet integrated
//  with signing" while `NativeSigningManager.exportToCertificateStore` was already handing the
//  account's pair to the ordinary certificate store, where the imported-certificate engine signs
//  with it. These tests pin the distinction so the two ideas cannot merge again.
//

import XCTest
@testable import VexSign

final class SigningMethodAvailabilityTests: XCTestCase {
    func testNoCaveatWhenTheInProcessAccountSignerRuns() {
        XCTAssertNil(SigningMethodAvailability.freeAppleIDReason(engine: .implemented))
    }

    func testTheCaveatNamesTheEngineThatSignsAndNotAMissingIntegration() throws {
        let reason = try XCTUnwrap(SigningMethodAvailability.freeAppleIDReason(engine: .notIntegrated))
        XCTAssertTrue(reason.contains("imported-certificate"), reason)
        XCTAssertTrue(reason.contains("certificate store"), reason)
        XCTAssertFalse(
            reason.lowercased().contains("not yet integrated with signing"),
            "Provisioning is wired to the certificate store; only the in-process signer is gated: \(reason)"
        )
    }

    func testTheFreeAccountMethodStaysSelectableWhileTheSignerIsGated() {
        // Selecting it starts sign-in and shows the live session; gating the in-process signer
        // must not turn the whole method into a dead row.
        let availability = SigningMethodAvailability.current(for: .freeAppleID)
        XCTAssertTrue(availability.isAvailable)
        XCTAssertEqual(
            availability.availabilityReason,
            SigningMethodAvailability.freeAppleIDReason(
                engine: SigningMethodCapabilities.current.nativeAppleAccountSigning
            )
        )
    }
}
