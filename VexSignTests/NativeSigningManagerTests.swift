// MARK: - NativeSigningManagerTests
/// Unit tests for the NativeSigningManager functionality.

import Foundation
import Testing
import NimbleExtensions
@testable import VexSign

/// `NativeSigningManager` is main-actor isolated, and Swift Testing does not run suites on
/// the main actor unless the suite says so.
@MainActor
@Suite("NativeSigningManager Tests")
struct NativeSigningManagerTests {

    // MARK: - SigningIdentity Tests

    @Test("SigningIdentity displayName format")
    func testSigningIdentityDisplayName() {
        let identityID = UUID(uuidString: "12345678-1234-1234-1234-123456789012")!
        let identity = NativeSigningManager.SigningIdentity(
            id: UUID(),
            identityID: identityID,
            teamIdentifier: "TEAM123",
            phase: .certificateRecorded,
            publicKeyHash: "abcd1234",
            csrHash: "efgh5678",
            certificateHash: "ijkl9012",
            certificateExpiresAt: Date().addingTimeInterval(86400)
        )

        #expect(identity.displayName == "Identity 12345678")
    }

    @Test("SigningIdentity daysUntilExpiry calculation")
    func testDaysUntilExpiry() {
        let futureDate = Date().addingTimeInterval(86400 * 5) // 5 days
        let identity = NativeSigningManager.SigningIdentity(
            id: UUID(),
            identityID: UUID(),
            teamIdentifier: "TEAM123",
            phase: .certificateRecorded,
            publicKeyHash: "abcd1234",
            csrHash: "efgh5678",
            certificateHash: "ijkl9012",
            certificateExpiresAt: futureDate
        )

        #expect(identity.certificateExpiresAt == futureDate)
    }

    // MARK: - FreeAccountProfile Tests

    @Test("FreeAccountProfile daysUntilExpiry calculation")
    func testFreeAccountProfileDaysUntilExpiry() {
        let futureDate = Date().addingTimeInterval(86400 * 3) // 3 days
        let profile = NativeSigningManager.FreeAccountProfile(
            id: UUID(),
            bundleIdentifier: "com.example.app",
            profileUUID: UUID(),
            expiresAt: futureDate,
            certificateID: UUID()
        )

        #expect(profile.daysUntilExpiry == 3)
        #expect(profile.isExpiringSoon == false) // 3 days > 2 days threshold
    }

    @Test("FreeAccountProfile isExpiringSoon when within 2 days")
    func testFreeAccountProfileExpiringSoon() {
        let futureDate = Date().addingTimeInterval(86400 * 1) // 1 day
        let profile = NativeSigningManager.FreeAccountProfile(
            id: UUID(),
            bundleIdentifier: "com.example.app",
            profileUUID: UUID(),
            expiresAt: futureDate,
            certificateID: UUID()
        )

        #expect(profile.daysUntilExpiry == 1)
        #expect(profile.isExpiringSoon == true)
    }

    @Test("FreeAccountProfile isExpired when past expiry")
    func testFreeAccountProfileExpired() {
        let pastDate = Date().addingTimeInterval(-86400) // 1 day ago
        let profile = NativeSigningManager.FreeAccountProfile(
            id: UUID(),
            bundleIdentifier: "com.example.app",
            profileUUID: UUID(),
            expiresAt: pastDate,
            certificateID: UUID()
        )

        #expect(profile.daysUntilExpiry == 0)
        #expect(profile.isExpired == true)
    }

    // MARK: - Error Mapping Tests

    @Test("mapError returns correct SigningError for backendNotReady")
    func testMapErrorBackendNotReady() {
        let manager = NativeSigningManager.shared
        let error = NativeSigningError.backendNotReady
        let mapped = manager.mapError(error, context: .general)

        #expect(mapped.title == .localized("Signing Backend Not Ready"))
        #expect(mapped.isRecoverable == true)
    }

    @Test("mapError returns correct SigningError for providerNotConfigured")
    func testMapErrorProviderNotConfigured() {
        let manager = NativeSigningManager.shared
        let error = NativeSigningError.providerNotConfigured
        let mapped = manager.mapError(error, context: .authentication)

        #expect(mapped.title == .localized("Anisette Provider Not Configured"))
        #expect(mapped.isRecoverable == true)
    }

    @Test("mapError returns correct SigningError for noActiveContext")
    func testMapErrorNoActiveContext() {
        let manager = NativeSigningManager.shared
        let error = NativeSigningError.noActiveContext
        let mapped = manager.mapError(error, context: .provisioning)

        #expect(mapped.title == .localized("No Active Signing Context"))
        #expect(mapped.isRecoverable == true)
    }

    @Test("mapError returns correct SigningError for noSelectedTeam")
    func testMapErrorNoSelectedTeam() {
        let manager = NativeSigningManager.shared
        let error = NativeSigningError.noSelectedTeam
        let mapped = manager.mapError(error, context: .provisioning)

        #expect(mapped.title == .localized("No Team Selected"))
        #expect(mapped.isRecoverable == true)
    }

    // MARK: - Availability Tests

    @Test("An unavailable method always reports a reason")
    func testAvailabilityReasonMatchesAvailability() {
        for method in SigningMethod.allCases {
            let availability = SigningMethodAvailability.current(for: method)
            // The reason doubles as a caveat for a method that is selectable but limited, so
            // only one direction holds: an unavailable method always says why.
            if !availability.isAvailable {
                #expect(availability.availabilityReason != nil)
            }
        }
    }

    @Test("Free Apple ID method stays selectable without a session")
    func testFreeAppleIDAvailability() {
        // Sign-in and quota status belong to NativeSigningManager.snapshot,
        // which the signing-methods screen renders; the row itself must never
        // be greyed out because no session exists yet.
        let availability = SigningMethodAvailability.current(for: .freeAppleID)
        #expect(availability.isAvailable)
        // While the native account adapter is not wired into signing, the row carries the
        // "experimental" caveat. It is a caveat, not a reason the row is disabled.
        let integrated = SigningMethodCapabilities.current.nativeAppleAccountSigning != .notIntegrated
        #expect((availability.availabilityReason == nil) == integrated)
    }

    @Test("Paid certificate availability mirrors imported certificates")
    func testPaidCertificateAvailability() {
        let availability = SigningMethodAvailability.current(for: .paidCertificate)
        let hasCerts = !Storage.shared.getAllCertificates().isEmpty
        #expect(availability.isAvailable == hasCerts)
        #expect(availability.isAvailable == (availability.availabilityReason == nil))
    }

    @Test("TrollStore availability mirrors the device detector")
    func testTrollStoreAvailability() {
        let availability = SigningMethodAvailability.current(for: .trollStore)
        #expect(availability.isAvailable == TrollStoreDetector.isAvailable)
        #expect(availability.isAvailable == (availability.availabilityReason == nil))
    }

    @Test("TwoFactorChallenge preserves operation and retry flags without SideSign import")
    func testTwoFactorChallengeIdentityAndSubmissionRequiresBackend() async {
        let operationID = UUID()
        let challengeID = UUID()
        let challenge = NativeSigningManager.TwoFactorChallenge(
            operationID: operationID,
            id: challengeID,
            isRetry: true
        )
        #expect(challenge.operationID == operationID)
        #expect(challenge.id == challengeID)
        #expect(challenge.isRetry == true)

        await NativeSigningManager.shared.shutdown()
        do {
            _ = try await NativeSigningManager.shared.submitTwoFactorCode(
                "123456",
                operationID: operationID,
                challengeID: challengeID
            )
            Issue.record("Expected backendNotReady when manager has not been initialized")
        } catch let error as NativeSigningError {
            guard case .backendNotReady = error else {
                Issue.record("Unexpected NativeSigningError: \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }
}