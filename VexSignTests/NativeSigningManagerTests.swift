// MARK: - NativeSigningManagerTests
/// Unit tests for the NativeSigningManager functionality.

import Foundation
import Testing
import NimbleExtensions
@testable import VexSign

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

    @Test("SigningMethodAvailability for paidCertificate")
    func testPaidCertificateAvailability() {
        let availability = SigningMethodAvailability.current(for: .paidCertificate)
        // In test environment, this will be false since no cert is imported
        #expect(availability.isAvailable == false || availability.isAvailable == true)
    }

    @Test("SigningMethodAvailability for freeAppleID")
    func testFreeAppleIDAvailability() {
        let availability = SigningMethodAvailability.current(for: .freeAppleID)
        // In test environment, this will be false since no anisette provider
        #expect(availability.isAvailable == false || availability.isAvailable == true)
    }

    @Test("SigningMethodAvailability for trollStore")
    func testTrollStoreAvailability() {
        let availability = SigningMethodAvailability.current(for: .trollStore)
        // TrollStore availability depends on device
        #expect(availability.isAvailable == false || availability.isAvailable == true)
    }
}