import XCTest
@testable import VexSign

final class SigningModeRoutingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func evidence(
        timeToLive: Int? = 365,
        identity: Bool = true,
        profile: Bool = true,
        revoked: Bool = false,
        certificateExpiration: Date? = nil,
        profileExpiration: Date? = nil,
        allDevices: Bool = false
    ) -> CertificateRoutingEvidence {
        CertificateRoutingEvidence(
            hasIdentityFile: identity,
            hasProvisioningProfile: profile,
            isRevoked: revoked,
            certificateExpiresAt: certificateExpiration ?? now.addingTimeInterval(86400 * 365),
            profileExpiresAt: profileExpiration ?? now.addingTimeInterval(86400 * 365),
            profileTimeToLive: timeToLive,
            provisionsAllDevices: allDevices
        )
    }

    func testAutomaticPrefersUsablePaidCertificateWhenContainerIsAlsoAvailable() throws {
        let pipeline = try InstallationRouter.resolve(InstallationRoutingInput(
            certificate: evidence(), hasEmbeddedRuntime: true, storedInstallationMethod: 1
        ), at: now)
        XCTAssertEqual(pipeline, .directPaid(.idevice))
        XCTAssertEqual(pipeline.installationMethodValue, 1)
    }

    func testAutomaticUsesContainerWithoutPaidCertificateEvidence() throws {
        for certificate in [nil, evidence(timeToLive: 7), evidence(timeToLive: nil)] {
            let pipeline = try InstallationRouter.resolve(InstallationRoutingInput(
                certificate: certificate, hasEmbeddedRuntime: true
            ), at: now)
            XCTAssertEqual(pipeline, .containerized)
        }
    }

    func testEnterpriseProfileCanBeAutomaticDirectCandidate() throws {
        let pipeline = try InstallationRouter.resolve(InstallationRoutingInput(
            certificate: evidence(timeToLive: 7, allDevices: true), hasEmbeddedRuntime: true
        ), at: now)
        XCTAssertEqual(pipeline, .directPaid(.server))
    }

    func testAutomaticStandaloneRetainsDirectPipelineForAlreadySignedPackages() throws {
        let pipeline = try InstallationRouter.resolve(InstallationRoutingInput(
            certificate: nil, hasEmbeddedRuntime: false, storedInstallationMethod: 1
        ), at: now)
        XCTAssertEqual(pipeline, .directPaid(.idevice))
    }

    func testExplicitDirectModeDoesNotRequireRuntimeOrGuessPaidEnrollment() throws {
        let pipeline = try InstallationRouter.resolve(InstallationRoutingInput(
            preference: .directPaid,
            certificate: evidence(timeToLive: 7),
            hasEmbeddedRuntime: true,
            storedInstallationMethod: 0
        ), at: now)
        XCTAssertEqual(pipeline, .directPaid(.server))
    }

    func testExplicitContainerFailsClosedWithoutProcessLocalRuntime() {
        XCTAssertThrowsError(try InstallationRouter.resolve(InstallationRoutingInput(
            preference: .containerized, certificate: evidence(), hasEmbeddedRuntime: false
        ), at: now)) { error in
            XCTAssertEqual(error as? InstallationRoutingError, .containerUnavailable)
        }
    }

    func testLegacyGuestInstallationValueRemainsContainerizedInAutomaticMode() throws {
        let pipeline = try InstallationRouter.resolve(InstallationRoutingInput(
            certificate: evidence(), hasEmbeddedRuntime: true, storedInstallationMethod: 2
        ), at: now)
        XCTAssertEqual(pipeline, .containerized)
    }

    func testDirectOverrideRestoresLastDirectTransportAfterLegacyGuestRoute() throws {
        let pipeline = try InstallationRouter.resolve(InstallationRoutingInput(
            preference: .directPaid,
            hasEmbeddedRuntime: true,
            storedInstallationMethod: 2,
            preferredDirectInstallationMethod: 1
        ), at: now)
        XCTAssertEqual(pipeline, .directPaid(.idevice))
    }

    func testInvalidStoredRoutesNeverBecomeOTA() {
        XCTAssertThrowsError(try InstallationRouter.resolve(InstallationRoutingInput(
            storedInstallationMethod: 99
        ), at: now)) { error in
            XCTAssertEqual(error as? InstallationRoutingError, .unknownInstallationMethod(99))
        }
        XCTAssertThrowsError(try InstallationRouter.resolve(InstallationRoutingInput(
            preference: .directPaid,
            storedInstallationMethod: 2,
            preferredDirectInstallationMethod: 2
        ), at: now)) { error in
            XCTAssertEqual(error as? InstallationRoutingError, .invalidDirectMethod(2))
        }
    }

    func testExpiredRevokedOrIncompleteCertificateIsNotAutomaticPaidEvidence() {
        let expired = evidence(certificateExpiration: now.addingTimeInterval(-1))
        let expiredProfile = evidence(profileExpiration: now.addingTimeInterval(-1))
        let candidates = [
            expired, expiredProfile, evidence(revoked: true),
            evidence(identity: false), evidence(profile: false)
        ]
        for candidate in candidates {
            XCTAssertFalse(candidate.isDirectPaidCandidate(at: now))
            XCTAssertNoThrow(try InstallationRouter.resolve(InstallationRoutingInput(
                certificate: candidate, hasEmbeddedRuntime: false
            ), at: now), "Standalone direct fallback must remain available for already signed packages")
        }
    }

    @MainActor
    func testModeSelectionPersistsAndRestoresDirectTransport() throws {
        let suite = "SigningModeRoutingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(1, forKey: SigningModeManager.preferredDirectMethodKey)
        defaults.set(2, forKey: "VexSign.installationMethod")

        let manager = SigningModeManager(defaults: defaults)
        XCTAssertEqual(manager.preference, .automatic)
        manager.selectPreference(.directPaid)
        XCTAssertEqual(defaults.integer(forKey: "VexSign.installationMethod"), 1)
        XCTAssertEqual(defaults.string(forKey: SigningModeManager.preferenceKey), "directPaid")

        manager.selectDirectMethod(0)
        XCTAssertEqual(defaults.integer(forKey: SigningModeManager.preferredDirectMethodKey), 0)
        manager.selectPreference(.containerized)
        XCTAssertEqual(manager.preference, .containerized)
        XCTAssertEqual(defaults.integer(forKey: "VexSign.installationMethod"), 0,
                       "Container mode must not overwrite the direct transport preference")
    }
}
