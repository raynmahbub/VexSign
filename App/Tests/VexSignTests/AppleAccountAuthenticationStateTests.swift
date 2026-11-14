import Foundation
import XCTest
@testable import VexSign

final class AppleAccountAuthenticationStateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)
    private func session(expiresAt: Date? = nil) -> AppleAccountSessionMetadata {
        AppleAccountSessionMetadata(credentialReference: UUID(), teams: [
            .init(identifier: "FREE", membership: .free),
            .init(identifier: "PAID", membership: .paid)
        ], expiresAt: expiresAt)
    }

    func testExplicitTeamSelectionIsRequiredAfterAuthentication() throws {
        var state = AppleAccountAuthenticationState()
        let operation = try XCTUnwrap(state.beginAuthentication())
        XCTAssertTrue(state.requireTwoFactor(operation: operation))
        let metadata = session()
        XCTAssertTrue(state.receiveAuthenticatedSession(operation: operation, session: metadata, now: now))
        XCTAssertNil(state.currentContext(at: now))
        XCTAssertFalse(state.selectTeam(identifier: "UNKNOWN", operation: operation, now: now))
        XCTAssertTrue(state.selectTeam(identifier: "PAID", operation: operation, now: now))
        XCTAssertEqual(state.currentContext(at: now)?.team.membership, .paid)
        XCTAssertFalse(state.requireTwoFactor(operation: operation))
    }

    func testRetryRejectsOlderChallengeSuccessAndFailureCallbacks() throws {
        var state = AppleAccountAuthenticationState()
        let old = try XCTUnwrap(state.beginAuthentication())
        let current = try XCTUnwrap(state.beginAuthentication())
        XCTAssertNotEqual(old, current)
        XCTAssertFalse(state.requireTwoFactor(operation: old))
        XCTAssertFalse(state.receiveAuthenticatedSession(operation: old, session: session(), now: now))
        XCTAssertFalse(state.failAuthentication(operation: old))
        XCTAssertEqual(state.phase, .authenticating(current))
        XCTAssertTrue(state.failAuthentication(operation: current))
        XCTAssertEqual(state.phase, .signedOut)
    }

    func testSignOutRejectsAnInFlightAuthenticationResult() throws {
        var state = AppleAccountAuthenticationState()
        let operation = try XCTUnwrap(state.beginAuthentication())
        XCTAssertNil(state.signOut())
        XCTAssertFalse(state.receiveAuthenticatedSession(operation: operation, session: session(), now: now))
        XCTAssertFalse(state.requireTwoFactor(operation: operation))
        XCTAssertEqual(state.phase, .signedOut)
    }

    func testCancellingTeamSelectionReturnsCredentialReferenceForDeletion() throws {
        var state = AppleAccountAuthenticationState()
        let operation = try XCTUnwrap(state.beginAuthentication())
        let metadata = session()
        XCTAssertTrue(state.receiveAuthenticatedSession(operation: operation, session: metadata, now: now))
        XCTAssertNil(state.beginAuthentication(), "Do not orphan an existing Keychain record")
        XCTAssertEqual(state.signOut(), metadata.credentialReference)
        XCTAssertNotNil(state.beginAuthentication())
    }

    func testTeamChangeInvalidatesInFlightProvisioningResults() throws {
        var state = AppleAccountAuthenticationState()
        let operation = try XCTUnwrap(state.beginAuthentication())
        XCTAssertTrue(state.receiveAuthenticatedSession(operation: operation, session: session(), now: now))
        XCTAssertTrue(state.selectTeam(identifier: "FREE", operation: operation, now: now))
        let old = try XCTUnwrap(state.currentContext(at: now))
        XCTAssertTrue(state.acceptsProvisioningResult(contextID: old.id, now: now))
        XCTAssertTrue(state.changeTeam(identifier: "PAID", now: now))
        XCTAssertFalse(state.acceptsProvisioningResult(contextID: old.id, now: now))
        let current = try XCTUnwrap(state.currentContext(at: now))
        XCTAssertNotEqual(old.id, current.id)
        XCTAssertEqual(current.team.membership, .paid)
        XCTAssertFalse(state.changeTeam(identifier: "UNAUTHORIZED", now: now))
        XCTAssertEqual(state.currentContext(at: now), current)
    }

    func testExpirationBlocksProvisioningEvenBeforeExplicitExpiryTransition() throws {
        var state = AppleAccountAuthenticationState()
        let operation = try XCTUnwrap(state.beginAuthentication())
        let metadata = session(expiresAt: now.addingTimeInterval(10))
        XCTAssertTrue(state.receiveAuthenticatedSession(operation: operation, session: metadata, now: now))
        XCTAssertTrue(state.selectTeam(identifier: "FREE", operation: operation, now: now))
        let context = try XCTUnwrap(state.currentContext(at: now))
        XCTAssertFalse(state.acceptsProvisioningResult(contextID: context.id, now: now.addingTimeInterval(10)))
        state.expireSession()
        XCTAssertNil(state.currentContext(at: now))
        XCTAssertNil(state.beginAuthentication())
        XCTAssertEqual(state.signOut(), metadata.credentialReference)
        XCTAssertFalse(state.acceptsProvisioningResult(contextID: context.id, now: now))
    }

    func testDuplicateCallbackDoesNotLoseTheAcceptedCredentialReference() throws {
        var state = AppleAccountAuthenticationState()
        let operation = try XCTUnwrap(state.beginAuthentication())
        let metadata = session()
        XCTAssertTrue(state.receiveAuthenticatedSession(operation: operation, session: metadata, now: now))
        XCTAssertFalse(state.receiveAuthenticatedSession(operation: operation, session: metadata, now: now))
        XCTAssertEqual(state.credentialReference, metadata.credentialReference)
        XCTAssertEqual(state.signOut(), metadata.credentialReference)
        XCTAssertNil(state.credentialReference)
    }

    func testExpiryDuringTeamSelectionRejectsLateSelection() throws {
        var state = AppleAccountAuthenticationState()
        let operation = try XCTUnwrap(state.beginAuthentication())
        let metadata = session()
        XCTAssertTrue(state.receiveAuthenticatedSession(operation: operation, session: metadata, now: now))
        state.expireSession()
        XCTAssertFalse(state.selectTeam(identifier: "FREE", operation: operation, now: now))
        XCTAssertEqual(state.signOut(), metadata.credentialReference)
    }

    func testInvalidSessionMetadataCannotBeAccepted() throws {
        let invalid = [
            AppleAccountSessionMetadata(credentialReference: UUID(), teams: [], expiresAt: nil),
            AppleAccountSessionMetadata(credentialReference: UUID(), teams: [.init(identifier: " ", membership: .free)], expiresAt: nil),
            AppleAccountSessionMetadata(credentialReference: UUID(), teams: [.init(identifier: "T", membership: .free), .init(identifier: "T", membership: .paid)], expiresAt: nil),
            session(expiresAt: now)
        ]
        for metadata in invalid {
            var state = AppleAccountAuthenticationState()
            let operation = try XCTUnwrap(state.beginAuthentication())
            XCTAssertFalse(state.receiveAuthenticatedSession(operation: operation, session: metadata, now: now))
            XCTAssertNil(state.currentContext(at: now))
        }
    }

    func testPrototypeDoesNotAdvertiseNativeAccountSigningOrPrimaryHosting() {
        let prototype = SigningMethodCapabilities.report(isGuestBuild: true, guestRuntimeLoaded: true)
        XCTAssertEqual(prototype.experimentalRuntime, .guestPrototypeLoaded)
        XCTAssertEqual(prototype.importedCertificateSigning, .implemented)
        XCTAssertEqual(prototype.nativeAppleAccountSigning, .notIntegrated)
        XCTAssertEqual(prototype.vexSignPrimaryHost, .notIntegrated)
        XCTAssertEqual(SigningMethodCapabilities.report(isGuestBuild: false, guestRuntimeLoaded: true).experimentalRuntime, .none)
    }

    func testSigningMethodsCanBeFoundByAccountAndCertificateKeywords() throws {
        let entry = try XCTUnwrap(SettingsSearchIndex.entries.first { $0.id == .signingMethods })
        XCTAssertTrue(SettingsSearchIndex.matches(entry, query: "free account"))
        XCTAssertTrue(SettingsSearchIndex.matches(entry, query: "paid certificate"))
    }
}
