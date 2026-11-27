//
//  UnifiedSigningIdentityTests.swift
//  VexSignTests
//
//  Deterministic fixtures only. No real certificate, private key, provider
//  credential, network call or Keychain entry is used in this suite.
//

import Foundation
import XCTest
@testable import VexSign

final class UnifiedSigningIdentityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Fixtures

    private func profile(
        id: String = "profile-1",
        team: String = "TEAM123456",
        type: String = "development",
        distribution: String = "development",
        devices: [String] = ["00000000-0000-0000-0000-000000000001"],
        platform: [String] = ["iOS"],
        entitlements: [VaultEntitlement] = [.init(key: "get-task-allow", value: "true")],
        fingerprints: [String] = []
    ) -> VaultProfile {
        VaultProfile(
            id: id, uuid: id, name: "Fixture Profile", appIdentifier: "com.example.app",
            teamIdentifier: team, teamName: "Fixture Team",
            applicationIdentifierPrefixes: [team], platforms: platform,
            creationDate: now.addingTimeInterval(-86_400),
            expirationDate: now.addingTimeInterval(30 * 86_400),
            type: type, distribution: distribution, provisionsAllDevices: false,
            provisionedDevices: devices, entitlements: entitlements,
            capabilities: entitlements.map(\.key), certificateFingerprints: fingerprints,
            parseStatus: .parsed, validity: .valid, limitations: [], importedAt: now
        )
    }

    private func certificateRecord(
        id: String = "x-coredata://fixture/cert/1",
        uuid: String = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
        nickname: String? = "paid-certificate",
        expiration: Date? = nil,
        revoked: Bool = false,
        profile: Certificate? = nil
    ) -> CertificateRecord {
        CertificateRecord(
            id: id, uuid: uuid, nickname: nickname, date: now, expiration: expiration,
            isDefault: false, ppQCheck: false, revoked: revoked, profile: profile,
            additionalProfilePatterns: []
        )
    }

    private func signedProfile(
        team: String = "TEAM123456",
        name: String = "Fixture",
        devices: [String]? = ["00000000-0000-0000-0000-000000000001"]
    ) -> Certificate {
        Certificate(
            AppIDName: name, ApplicationIdentifierPrefix: [team], CreationDate: now,
            Platform: ["iOS"], IsXcodeManaged: false, DeveloperCertificates: nil,
            derEncodedProfile: nil, PPQCheck: false,
            Entitlements: ["get-task-allow": AnyCodable(true)],
            ExpirationDate: now.addingTimeInterval(30 * 86_400), Name: name,
            ProvisionsAllDevices: false, ProvisionedDevices: devices,
            TeamIdentifier: [team], TeamName: "Fixture Team", TimeToLive: 30,
            UUID: "profile-uuid", Version: 1
        )
    }

    private func input(
        reference: String = "x-coredata://fixture/cert/1",
        password: String? = "fixture-password",
        revoked: Bool = false
    ) -> SigningIdentityStore.Input {
        SigningIdentityStore.Input(
            reference: reference, name: "Fixture", p12URL: password == nil ? nil : URL(fileURLWithPath: "/fixture/cert.p12"),
            profileURLs: [], password: password, revoked: revoked, notice: nil
        )
    }

    private func identity(
        source: UnifiedIdentitySource = .externalImport,
        type: SigningCertificateType = .development,
        state: SigningIdentityValidityState = .valid,
        fingerprint: String? = "aabbccddeeff",
        engineReady: Bool = true,
        team: String? = "TEAM123456"
    ) -> UnifiedSigningIdentity {
        UnifiedSigningIdentity(
            id: "identity-1", displayName: "Fixture", source: source, certificateType: type,
            teamIdentifier: team, fingerprint: fingerprint,
            notBefore: now.addingTimeInterval(-86_400), notAfter: now.addingTimeInterval(30 * 86_400),
            privateKeyAvailable: true, associatedProfileIDs: ["profile-1"],
            supportedPlatforms: ["iOS"], capabilities: ["get-task-allow"],
            validityState: state, engineReady: engineReady, engineReference: engineReady ? "x-coredata://fixture/cert/1" : nil,
            providerID: .localCertificateFiles, notices: []
        )
    }

    // MARK: - Identity model

    func testNicknameNeverSetsSourceOrCertificateType() {
        let candidates = [UnifiedIdentityCatalog.EngineCandidate(
            input: input(), record: certificateRecord(nickname: "paid enterprise distribution cert")
        )]
        let identity = UnifiedIdentityCatalog.engineIdentities(
            from: candidates, now: now, provenance: { _ in nil }
        ).first
        XCTAssertEqual(identity?.source, .externalImport)
        XCTAssertEqual(identity?.certificateType, .development)
        XCTAssertTrue(identity?.engineReady ?? false)
    }

    func testExplicitProvenanceSetsSourceWithoutNameInference() throws {
        let uuid = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        let candidates = [UnifiedIdentityCatalog.EngineCandidate(
            input: input(), record: certificateRecord(uuid: uuid, nickname: "anything")
        )]
        let identity = try XCTUnwrap(UnifiedIdentityCatalog.engineIdentities(
            from: candidates, now: now, provenance: { _ in .communityNexCerts }
        ).first)
        XCTAssertEqual(identity.source, .externalProvider)
        XCTAssertEqual(identity.providerID, .communityNexCerts)
    }

    func testVaultIdentityIsHonestlyNotEngineReady() {
        let certificate = VaultCertificate(
            id: "vault-1", fingerprint: "AABBCC", displayName: "vault identity",
            commonName: nil, issuerCommonName: nil, teamIdentifier: "TEAM123456",
            serialNumber: nil, notBefore: now.addingTimeInterval(-86_400),
            notAfter: now.addingTimeInterval(30 * 86_400), keyAlgorithm: nil,
            keySizeBits: nil, importedAt: now, keyState: .accessible
        )
        let identity = UnifiedIdentityCatalog.vaultIdentities(
            certificates: [certificate], profiles: [profile(fingerprints: ["aabbcc"])], now: now
        ).first
        XCTAssertFalse(identity?.engineReady ?? true)
        XCTAssertFalse(identity?.canStartNativeSigning ?? true)
        XCTAssertEqual(identity?.fingerprint, "AABBCC")
    }

    func testExpiryAndMissingKeyBlockSigning() {
        let expired = UnifiedIdentityCatalog.engineIdentities(
            from: [.init(input: input(), record: certificateRecord(expiration: now.addingTimeInterval(-1)))],
            now: now, provenance: { _ in nil }
        ).first
        XCTAssertEqual(expired?.validityState, .expired)
        XCTAssertFalse(expired?.canStartNativeSigning ?? true)

        let noKey = UnifiedIdentityCatalog.engineIdentities(
            from: [.init(input: input(password: nil), record: certificateRecord())],
            now: now, provenance: { _ in nil }
        ).first
        XCTAssertEqual(noKey?.validityState, .keyMissing)
        XCTAssertFalse(noKey?.canStartNativeSigning ?? true)
    }

    // MARK: - Compatibility

    func testEnterpriseProfileIsNotReportedAsOrdinaryPaidCert() {
        let result = UnifiedIdentityCompatibility.evaluate(
            identity: identity(), profile: profile(type: "enterprise", distribution: "enterprise"),
            target: VaultCompatibilityTarget(bundleIdentifier: "com.example.app"), now: now
        )
        XCTAssertEqual(result.outcome, .unsupported)
        XCTAssertTrue(result.reasons.contains { $0.contains("enterprise distribution") })
    }

    func testAppStoreProfileCannotInstallDirectlyOnDevice() {
        let result = UnifiedIdentityCompatibility.evaluate(
            identity: identity(), profile: profile(type: "distribution", distribution: "distribution"),
            target: VaultCompatibilityTarget(bundleIdentifier: "com.example.app",
                                             deviceIdentifier: "00000000-0000-0000-0000-000000000001"),
            now: now
        )
        XCTAssertEqual(result.outcome, .unsupported)
    }

    func testUnknownFingerprintNeedsAdditionalValidation() {
        let result = UnifiedIdentityCompatibility.evaluate(
            identity: identity(fingerprint: nil), profile: profile(),
            target: VaultCompatibilityTarget(bundleIdentifier: "com.example.app",
                                             teamIdentifier: "TEAM123456"),
            now: now
        )
        XCTAssertEqual(result.outcome, .requiresAdditionalValidation)
    }

    func testMismatchedTeamIsIncompatible() {
        let result = UnifiedIdentityCompatibility.evaluate(
            identity: identity(), profile: profile(team: "OTHERTEAM123"),
            target: VaultCompatibilityTarget(bundleIdentifier: "com.example.app",
                                             teamIdentifier: "TEAM123456"),
            now: now
        )
        XCTAssertNotEqual(result.outcome, .compatible)
    }

    // MARK: - Providers

    func testProviderRegistryOnlyExposesVerifiedCapabilities() {
        XCTAssertTrue(SigningProviderRegistry.descriptors[.communityNexCerts]?
            .supports(.certificateList) ?? false)
        XCTAssertFalse(SigningProviderRegistry.descriptors[.communityNexCerts]?
            .supports(.remoteSigning) ?? true)
        XCTAssertFalse(SigningProviderRegistry.descriptors[.appleDeveloper]?
            .supports(.authentication) ?? true)
    }

    func testCatalogueRetryIsBoundedAndRateLimitSurfaces() async throws {
        var attempts = 0
        let items = try await NexCerts.fetchCatalog(attempts: 3, load: {
            attempts += 1
            if attempts < 3 { throw NexCertsError.rateLimited(retryAfterSeconds: 0.25) }
            return [NexCerts.CatalogItem(
                id: 7, name: "fixture", certificateType: "Unknown", status: .unknown,
                rawStatusText: "", validFrom: "", validTo: "", folderName: "", order: 0
            )]
        }, sleep: { _ in })
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(attempts, 3)

        attempts = 0
        do {
            _ = try await NexCerts.fetchCatalog(attempts: 1, load: {
                attempts += 1
                throw NexCertsError.rateLimited(retryAfterSeconds: 1)
            }, sleep: { _ in })
            XCTFail("rate limit must surface")
        } catch NexCertsError.rateLimited {
            XCTAssertEqual(attempts, 1)
        }
    }

    func testMalformedCatalogueIsRejected() async {
        do {
            _ = try await NexCerts.fetchCatalog(load: { [] }, sleep: { _ in })
            XCTFail("empty catalogue must be rejected")
        } catch NexCertsError.emptyCatalog { }
    }

    func testCancellationAndDisconnectLeaveCertificatesAlone() async throws {
        let defaults = UserDefaults(suiteName: "UnifiedSigningIdentityTests.\(UUID().uuidString)")!
        NexCertsAccess.acknowledge(defaults)
        let adapter = NexCertsProviderAdapter(defaults: defaults, load: { [] })
        let initialStatus = try await adapter.status()
        XCTAssertEqual(initialStatus.state, .available)
        await adapter.cancel()
        do {
            _ = try await adapter.offerings()
            XCTFail("cancelled adapter must not load a catalogue")
        } catch SigningProviderError.cancelled { }
        let cancelledAdapter = NexCertsProviderAdapter(defaults: defaults, load: { [] })
        try await cancelledAdapter.disconnect()
        XCTAssertFalse(NexCertsAccess.hasAcknowledged(defaults))
        let finalStatus = try await cancelledAdapter.status()
        XCTAssertEqual(finalStatus.state, .notConfigured)
    }

    func testNetworkFailureIsDistinctFromMalformedResponse() {
        XCTAssertEqual(NexCertsProviderAdapter.translate(NexCertsError.invalidJSON), .malformedResponse)
        XCTAssertEqual(NexCertsProviderAdapter.translate(NexCertsError.invalidResponse(URL(fileURLWithPath: "/x"))), .malformedResponse)
        XCTAssertEqual(NexCertsProviderAdapter.translate(NexCertsError.downloadTooLarge(URL(fileURLWithPath: "/x"))), .networkFailure)
        XCTAssertEqual(NexCertsProviderAdapter.translate(NexCertsError.rateLimited(retryAfterSeconds: 2)), .rateLimited(retryAfterSeconds: 2))
    }

    func testRetryPolicyCapsDelayAndAttempts() {
        let policy = ProviderRetryPolicy(maximumAttempts: 2, maximumDelay: 5)
        XCTAssertEqual(policy.delay(for: 0, retryAfter: nil), 0.5)
        XCTAssertEqual(policy.delay(for: 0, retryAfter: 3600), 5)
        XCTAssertNil(policy.delay(for: 1, retryAfter: 1))
    }

    // MARK: - Security and lifecycle

    func testCredentialStoreNeverReturnsEmptyOrOversizedValue() throws {
        let store = ProviderCredentialStore(provider: .communityNexCerts)
        var written: String?
        XCTAssertThrowsError(try store.write("") { _, _, _ in })
        try store.write("fixture-token") { value, _, _ in written = String(decoding: value, as: UTF8.self) }
        XCTAssertEqual(written, "fixture-token")
        let read = try store.read { _, _ in written.map { Data($0.utf8) } }
        XCTAssertEqual(read, "fixture-token")
        XCTAssertThrowsError(try store.read { _, _ in Data(repeating: 0x61, count: 70_000) })
        XCTAssertEqual(ProviderCredentialStore.redacted(read), "Stored (hidden)")
        XCTAssertFalse(ProviderCredentialStore.redacted(read)?.contains("fixture") ?? true)
    }

    func testLifecyclePreservesValidIdentitiesWhenRefreshFails() {
        let valid: Set<String> = ["identity-1", "identity-2"]
        XCTAssertEqual(SigningIdentityLifecycle.preservedAfterRefreshFailure(validIdentityIDs: valid), valid)
        let decision = SigningIdentityLifecycle.decision(
            for: identity(state: .expired), validIdentityIDs: valid, providerStatus: nil, now: now
        )
        XCTAssertTrue(decision.preservedValidIdentities.contains("identity-2"))
        XCTAssertFalse(decision.actions.contains { if case .refresh = $0 { return true } else { return false } })
    }

    func testExpiringCommunityIdentityCanRefreshButNeverSilentlyReplace() {
        var expiring = identity(state: .expiringSoon)
        expiring.providerID = .communityNexCerts
        let decision = SigningIdentityLifecycle.decision(
            for: expiring, validIdentityIDs: ["other"],
            providerStatus: .init(provider: .communityNexCerts, state: .available, detail: "", checkedAt: now),
            now: now
        )
        XCTAssertTrue(decision.actions.contains { if case .refresh = $0 { return true } else { return false } })
        XCTAssertFalse(decision.actions.contains { if case .replaceValidIdentityPending = $0 { return true } else { return false } })
    }

    func testOnlyVaultLabelsAreOrphanCandidates() {
        let ids = SigningIdentityLifecycle.orphanedKeychainIDs(
            keychainLabels: ["com.vexsign.vault.identity.orphan", "com.vexsign.vault.identity.keep", "other.label"],
            vaultIDs: ["keep"]
        )
        XCTAssertEqual(ids, ["orphan"])
        XCTAssertEqual(SigningIdentityLifecycle.cleanupPlan(orphanedIDs: ids).count, 1)
    }

    func testEndToEndEligibilityRequiresEngineReadyAndValidProfile() {
        let eligible = identity()
        XCTAssertTrue(eligible.canStartNativeSigning)
        XCTAssertNoThrow(try EngineIdentityBinding(identity: eligible).validate())

        let vaultOnly = identity(engineReady: false)
        XCTAssertFalse(vaultOnly.canStartNativeSigning)
        XCTAssertThrowsError(try EngineIdentityBinding(identity: vaultOnly).validate())

        let revoked = identity(state: .revoked)
        XCTAssertThrowsError(try EngineIdentityBinding(identity: revoked).validate())

        let compatible = UnifiedIdentityCompatibility.evaluate(
            identity: eligible,
            profile: profile(fingerprints: ["aabbccddeeff"]),
            target: VaultCompatibilityTarget(bundleIdentifier: "com.example.app",
                                             teamIdentifier: "TEAM123456",
                                             entitlements: ["get-task-allow": "true"],
                                             platforms: ["iOS"]),
            now: now
        )
        XCTAssertEqual(compatible.outcome, .compatible)
        // Compatibility is necessary but not sufficient: the engine still uses
        // the existing staged p12 and the mandatory verification report.
        XCTAssertTrue(eligible.canStartNativeSigning)
    }
}
