//
//  ProvisioningConsentStateTests.swift
//  VexSignTests
//
//  The provisioning flow used to keep six approval booleans in `@State` across two
//  view files, and the rule that decided whether it could submit lived inside a
//  `.disabled(…)` expression. Nothing could test it, and the screen offered no
//  sentence when it was disabled. These tests are the table that used to be
//  unreachable: what counts as complete, what a reset clears, and which reason the
//  button reports first.
//

import XCTest
@testable import VexSign

final class ProvisioningConsentStateTests: XCTestCase {
    private func complete() -> ProvisioningConsentState {
        var state = ProvisioningConsentState()
        state.certificate = true
        state.registration = true
        state.profile = true
        return state
    }

    func testNothingIsApprovedUntilTheUserApprovesIt() {
        let state = ProvisioningConsentState()
        XCTAssertFalse(state.isComplete)
        XCTAssertEqual(state.approval, AppleAccountProvisioningApproval(certificate: false, registration: false, profile: false))
    }

    func testAllThreeApprovalsAreRequired() {
        let approvals: [WritableKeyPath<ProvisioningConsentState, Bool>] = [\.certificate, \.registration, \.profile]
        for missing in approvals {
            var state = complete()
            state[keyPath: missing] = false
            XCTAssertFalse(state.isComplete, "\(missing) must gate the submission")
            XCTAssertFalse(state.approval.isComplete)
        }
    }

    func testTheApprovalObjectMirrorsTheValue() {
        let state = complete()
        XCTAssertTrue(state.isComplete)
        XCTAssertEqual(state.approval, AppleAccountProvisioningApproval(certificate: true, registration: true, profile: true))
    }

    func testRenewalModeStartsWithALaterProfile() {
        // A renewal whose profile does not outlive the signed copy is not a
        // renewal, so the flag starts on where the flow was opened from it.
        XCTAssertTrue(ProvisioningConsentState(cellularReview: true).laterProfile)
        XCTAssertFalse(ProvisioningConsentState(cellularReview: false).laterProfile)
    }

    func testResetClearsEveryApprovalButKeepsTheRenewalIntent() {
        var state = ProvisioningConsentState(cellularReview: true)
        state.certificate = true
        state.registration = true
        state.profile = true
        state.regeneration = true
        state.keyExport = true

        state.reset()

        XCTAssertFalse(state.certificate)
        XCTAssertFalse(state.registration)
        XCTAssertFalse(state.profile)
        XCTAssertFalse(state.regeneration)
        XCTAssertFalse(state.keyExport)
        XCTAssertTrue(state.laterProfile, "The renewal intent describes the app, not this submission")
    }

    func testTheBlockedReasonNamesTheFirstThingTheUserHasToDo() {
        let incomplete = ProvisioningConsentState()
        // Signed out wins over every other precondition: nothing else can be fixed
        // before there is an account.
        XCTAssertNotNil(incomplete.blockedReason(hasSession: false, hasApp: false, isProvisioning: false))
        XCTAssertNotNil(incomplete.blockedReason(hasSession: true, hasApp: false, isProvisioning: false))
        XCTAssertNotNil(incomplete.blockedReason(hasSession: true, hasApp: true, isProvisioning: false))
        XCTAssertNotNil(incomplete.blockedReason(hasSession: true, hasApp: true, isProvisioning: true))
    }

    func testACompleteConsentWithASessionAndAnAppHasNoBlockedReason() {
        XCTAssertNil(complete().blockedReason(hasSession: true, hasApp: true, isProvisioning: false))
    }

    func testAProvisioningRunThatIsAlreadyUnderwayStillSaysSo() {
        // The button is disabled during the run; the sentence has to explain the
        // pause rather than repeat "approve the three items", which is already done.
        XCTAssertNotNil(complete().blockedReason(hasSession: true, hasApp: true, isProvisioning: true))
    }
}
