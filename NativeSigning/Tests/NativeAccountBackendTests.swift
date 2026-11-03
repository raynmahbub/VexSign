import Foundation
import XCTest
@testable import NativeSigningLinkSmoke

final class NativeAccountBackendTests: XCTestCase {
    private typealias Coordinator = AppleAccountSessionCoordinator<AppleAccountCredentialStore<SystemAppleAccountKeychainClient>, AppleAccountResumeJournalStore<SystemAppleAccountKeychainClient>>

    private func descriptor(endpoint: URL? = URL(string: "https://provider.example.invalid/headers")) throws -> AnisetteProviderDescriptor {
        try AnisetteProviderDescriptor(identifier: "fixture", displayName: "Synthetic provider", policyRevision: "1", endpoint: endpoint)
    }

    func testRuntimeFlagMatchesExistingGuestGuard() {
        XCTAssertFalse(AppleAccountStorageRuntimePolicy.isGuestBuild(metadata: [:]))
        XCTAssertFalse(AppleAccountStorageRuntimePolicy.isGuestBuild(metadata: ["VexSignEmbeddedGuest": false]))
        XCTAssertTrue(AppleAccountStorageRuntimePolicy.isGuestBuild(metadata: ["VexSignEmbeddedGuest": true]))
    }

    func testNamespaceLeaseExcludesSecondOwnerAndReleases() throws {
        var lease: NativeAccountNamespaceLease? = try NativeAccountNamespaceLease.acquire()
        XCTAssertNotNil(lease)
        XCTAssertThrowsError(try NativeAccountNamespaceLease.acquire()) {
            XCTAssertEqual($0 as? NativeAccountBackendError, .alreadyInUse)
        }
        lease = nil
        let next = try NativeAccountNamespaceLease.acquire()
        withExtendedLifetime(next) {
            XCTAssertThrowsError(try NativeAccountNamespaceLease.acquire())
        }
    }

    func testInvalidConfigurationDoesNotLeakLease() throws {
        XCTAssertThrowsError(try NativeAccountBackend(provider: descriptor(endpoint: nil))) {
            XCTAssertEqual($0 as? NativeAccountBackendError, .invalidConfiguration)
        }
        let lease = try NativeAccountNamespaceLease.acquire()
        withExtendedLifetime(lease) {}
    }

    // Valid construction creates ephemeral sessions but makes NO Keychain call,
    // provider request or Apple request. No account credentials are used here.
    func testShutdownClosesEventsAndRejectsNewConsentWithoutDeletingAccount() async throws {
        let backend = try NativeAccountBackend(provider: descriptor())
        let before = try await backend.snapshot()
        XCTAssertEqual(before, NativeAccountSnapshot(phase: .signedOut, cleanupRequired: false))
        var events = try await backend.events().makeAsyncIterator()
        await backend.shutdown()
        await backend.shutdown()
        let end = await events.next()
        XCTAssertNil(end)
        do { _ = try await backend.recordExplicitAnisetteConsent(); XCTFail("Closed") }
        catch { XCTAssertEqual(error as? NativeAccountBackendError, .closed) }
        do { _ = try await backend.snapshot(); XCTFail("Closed") }
        catch { XCTAssertEqual(error as? NativeAccountBackendError, .closed) }
    }

    func testClosedFacadeStillOwnsNamespaceUntilReleased() async throws {
        var backend: NativeAccountBackend? = try NativeAccountBackend(provider: descriptor())
        await backend?.shutdown()
        XCTAssertThrowsError(try NativeAccountBackend(provider: descriptor())) {
            XCTAssertEqual($0 as? NativeAccountBackendError, .alreadyInUse)
        }
        backend = nil
        let next = try NativeAccountBackend(provider: descriptor())
        await next.shutdown()
    }

    func testProjectionIncludesTeamsButNotCredentialReference() {
        let operation = UUID()
        let metadata = AppleAccountSessionMetadata(credentialReference: UUID(), teams: [
            .init(identifier: "FREE", membership: .free),
            .init(identifier: "PROGRAM", membership: .developerProgramUnverified)
        ], expiresAt: Date(timeIntervalSince1970: 900))
        let projected = NativeAccountBackend.project(Coordinator.Snapshot(phase: .awaitingTeamSelection(operation, metadata), cleanupRequired: false))
        XCTAssertEqual(projected.phase, .awaitingTeamSelection(operation, [
            NativeAccountTeam(identifier: "FREE", membership: .free),
            NativeAccountTeam(identifier: "PROGRAM", membership: .developerProgramUnverified)
        ], expiresAt: metadata.expiresAt))
    }

    func testSignedInProjectionUsesContextIDNotStorageReference() {
        let metadata = AppleAccountSessionMetadata(credentialReference: UUID(), teams: [.init(identifier: "TEAM", membership: .free)], expiresAt: nil)
        let context = AppleAccountAuthenticationState.Context(id: UUID(), session: metadata, team: metadata.teams[0])
        let projected = NativeAccountBackend.project(Coordinator.Snapshot(phase: .signedIn(context), cleanupRequired: false))
        XCTAssertEqual(projected.phase, .signedIn(NativeAccountContext(id: context.id, team: .init(identifier: "TEAM", membership: .free), expiresAt: nil)))
    }

    func testExpiredProjectionPreservesCleanupWarning() {
        let metadata = AppleAccountSessionMetadata(credentialReference: UUID(), teams: [], expiresAt: Date(timeIntervalSince1970: 1))
        let projected = NativeAccountBackend.project(Coordinator.Snapshot(phase: .expired(metadata), cleanupRequired: true))
        XCTAssertEqual(projected.phase, .expired(expiresAt: metadata.expiresAt))
        XCTAssertTrue(projected.cleanupRequired)
    }
}
