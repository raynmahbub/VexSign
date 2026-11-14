import XCTest
@testable import VexSign

/// Mandatory-rule tests inject authentication/key-proof outcomes at the domain
/// seam. These caller-constructed candidates are NOT actual Apple credentials.
final class ComponentSigningResolverTests: XCTestCase {
    private let now = SigningRegressionFixture.now
    private let team = SigningRegressionFixture.team

    private func target(_ identifier: String = "com.example.app", path: String = ".", platform: String = "iOS",
                        entitlements: [String: Any] = [:], parent: String? = nil) -> BundleSigningTarget {
        .init(relativePath: path, bundleIdentifier: identifier, platform: platform,
            requiredEntitlements: entitlements, parentBundleIdentifier: parent)
    }

    private func candidate(_ pattern: String, id: String, team: String = SigningRegressionFixture.team,
                           prefix: String? = nil, grants: [String: Any] = [:], allDevices: Bool = true,
                           devices: [String]? = nil, platform: [String] = ["iOS"],
                           key: SigningIdentityCandidate.KeyAvailability = .accessible) throws -> SigningProfileCandidate {
        .init(id: id, identity: .init(reference: id, fingerprint: "test-fingerprint-" + id,
            teamIdentifier: team, displayName: "Same display name", notBefore: now.addingTimeInterval(-100),
            notAfter: now.addingTimeInterval(10_000), keyAvailability: key),
            profile: try SigningRegressionFixture.profile(pattern: pattern, team: team, prefix: prefix, grants: grants,
                allDevices: allDevices, devices: devices, platform: platform, uuid: UUID().uuidString),
            isAuthenticated: true, authorizedCertificateFingerprints: ["test-fingerprint-" + id])
    }

    private func evaluate(_ candidate: SigningProfileCandidate, target: BundleSigningTarget? = nil,
                          device: String? = nil) -> SigningComponentResolution {
        ProfileCompatibilityValidator.evaluate(candidate, for: target ?? self.target(), deviceUDID: device, now: now)
    }

    func testExactPrecedesAValidWildcardEvenWhenTheWildcardIdentityWasPreferred() throws {
        let exact = try candidate(team + ".com.example.app", id: "exact")
        let wildcard = try candidate(team + ".*", id: "wildcard")
        let resolution = CompatibleIdentityResolver.resolve(targets: [target()], candidates: [wildcard, exact],
            deviceUDID: nil, preferredIdentity: "wildcard", now: now)
        XCTAssertTrue(resolution.isReady)
        XCTAssertEqual(resolution.components.first?.candidate?.id, "exact")
    }

    func testInvalidExactCandidateCannotBeatACompatibleWildcard() throws {
        let exact = try candidate(team + ".com.example.app", id: "exact")
        let wildcard = try candidate(team + ".com.example.*", id: "wildcard", grants: ["aps-environment": "development"])
        let resolution = CompatibleIdentityResolver.resolve(targets: [target(entitlements: ["aps-environment": "development"])],
            candidates: [exact, wildcard], deviceUDID: nil, preferredIdentity: "exact", now: now)
        XCTAssertTrue(resolution.isReady)
        XCTAssertEqual(resolution.components.first?.candidate?.id, "wildcard")
    }

    func testResolverBacktracksMainTeamUntilEveryRetainedExtensionIsCompatible() throws {
        let other = "OTHERTEAM0"
        let mainA = try candidate(team + ".com.example.app", id: "a-main")
        let mainB = try candidate(other + ".com.example.app", id: "b-main", team: other)
        let extensionB = try candidate(other + ".com.example.app.widget", id: "b-extension", team: other)
        let widget = target("com.example.app.widget", path: "PlugIns/Widget.appex", parent: "com.example.app")
        let result = CompatibleIdentityResolver.resolve(targets: [target(), widget],
            candidates: [mainA, mainB, extensionB], deviceUDID: nil, preferredIdentity: "a-main", now: now)
        XCTAssertTrue(result.isReady)
        XCTAssertEqual(result.components.map { $0.candidate?.id }, ["b-main", "b-extension"])
        XCTAssertNotEqual(result.components[0].candidate?.identity.fingerprint, result.components[1].candidate?.identity.fingerprint)
    }

    func testSameTeamCanUseDifferentCertificatesAndProfilesPerComponent() throws {
        let main = try candidate(team + ".com.example.app", id: "main")
        let widget = try candidate(team + ".com.example.app.widget", id: "widget")
        let result = CompatibleIdentityResolver.resolve(targets: [target(), target("com.example.app.widget", path: "Odd/Widget.appex", parent: "com.example.app")],
            candidates: [widget, main], deviceUDID: nil, now: now)
        XCTAssertTrue(result.isReady)
        XCTAssertEqual(result.components.map { $0.candidate?.id }, ["main", "widget"])
    }

    func testStaleExplicitPreferenceBlocksInsteadOfSilentlySubstituting() throws {
        let valid = try candidate(team + ".com.example.app", id: "available")
        let stale = ComponentSigningPreference(certificateFingerprint: "removed", profileUUID: UUID().uuidString)
        let result = CompatibleIdentityResolver.resolve(targets: [target()], candidates: [valid], deviceUDID: nil,
            preferences: [".": stale], now: now)
        XCTAssertFalse(result.isReady)
        XCTAssertNil(result.components.first?.candidate)
        XCTAssertEqual(result.components.first?.issues.first?.code, .noCandidate)
    }

    func testIncompatibleExplicitPreferenceCannotBeOverriddenByAutomaticAlternative() throws {
        let invalid = try candidate(team + ".com.other.app", id: "chosen")
        let valid = try candidate(team + ".com.example.app", id: "alternative")
        let result = CompatibleIdentityResolver.resolve(targets: [target()], candidates: [invalid, valid], deviceUDID: nil,
            preferences: [".": invalid.preference], now: now)
        XCTAssertFalse(result.isReady)
        XCTAssertEqual(result.components.first?.candidate?.id, "chosen")
        XCTAssertTrue(result.issues.contains { $0.code == .identifier })
    }

    func testAuthenticationIsMandatoryEvenWithMatchingNamesIdentifiersAndKeys() throws {
        let value = try candidate(team + ".com.example.app", id: "untrusted")
        let untrusted = SigningProfileCandidate(id: value.id, identity: value.identity, profile: value.profile,
            isAuthenticated: false, authorizedCertificateFingerprints: value.authorizedCertificateFingerprints)
        let result = evaluate(untrusted)
        XCTAssertEqual(result.status, .invalid)
        XCTAssertTrue(result.issues.contains { $0.code == .authenticity })
    }

    func testCertificateMembershipCannotBeInferredFromTeamOrDisplayName() throws {
        let value = try candidate(team + ".com.example.app", id: "unlisted")
        let unlisted = SigningProfileCandidate(id: value.id, identity: value.identity, profile: value.profile,
            isAuthenticated: true, authorizedCertificateFingerprints: ["another-leaf"])
        XCTAssertTrue(evaluate(unlisted).issues.contains { $0.code == .certificate })
        XCTAssertEqual(evaluate(unlisted).status, .invalid)
    }

    func testMissingAndInaccessiblePrivateKeysHaveDifferentTypedOutcomes() throws {
        let missing = try candidate(team + ".com.example.app", id: "missing", key: .missing)
        let inaccessible = try candidate(team + ".com.example.app", id: "locked", key: .inaccessible)
        XCTAssertEqual(evaluate(missing).status, .invalid)
        XCTAssertEqual(evaluate(inaccessible).status, .ambiguous)
        XCTAssertTrue(evaluate(missing).issues.contains { $0.code == .privateKey && $0.detail.contains("missing") })
        XCTAssertTrue(evaluate(inaccessible).issues.contains { $0.code == .privateKey && $0.detail.contains("inaccessible") })
    }

    func testUnsupportedNativeIssuerIsNotShownAsReady() throws {
        let value = try candidate(team + ".com.example.app", id: "new-issuer")
        var identity = value.identity; identity.nativeSigningSupported = false
        let unsupported = SigningProfileCandidate(id: value.id, identity: identity, profile: value.profile,
            isAuthenticated: true, authorizedCertificateFingerprints: value.authorizedCertificateFingerprints)
        let result = evaluate(unsupported)
        XCTAssertEqual(result.status, .unsupported)
        XCTAssertTrue(result.issues.contains { $0.code == .certificate && $0.detail.contains("CMS writer") })
    }

    func testProfileAndLeafValidityWindowsAreRecheckedAtTheExecutionDate() throws {
        let value = try candidate(team + ".com.example.app", id: "expires")
        var expired = value.profile; expired.ExpirationDate = now
        let candidate = SigningProfileCandidate(id: value.id, identity: value.identity, profile: expired,
            isAuthenticated: true, authorizedCertificateFingerprints: value.authorizedCertificateFingerprints)
        XCTAssertTrue(evaluate(candidate).issues.contains { $0.code == .expiration })
        let later = ProfileCompatibilityValidator.evaluate(value, for: target(), deviceUDID: nil, now: now.addingTimeInterval(10_000))
        XCTAssertTrue(later.issues.contains { $0.code == .certificate })
    }

    func testDeviceLimitedProfilesNeedTheExactAuthorizedTargetDevice() throws {
        let udid = "00008030-ABCDEF0123456789"
        let value = try candidate(team + ".com.example.app", id: "device", grants: ["get-task-allow": true],
            allDevices: false, devices: [udid])
        XCTAssertEqual(evaluate(value).status, .ambiguous)
        XCTAssertEqual(evaluate(value, device: "00008030-0000000000000000").status, .invalid)
        XCTAssertEqual(evaluate(value, device: udid.lowercased()).status, .valid)
    }

    func testWatchCannotBorrowAnIPhoneUDIDAsDeviceAuthorization() throws {
        let value = try candidate(team + ".com.example.app.watch", id: "watch", grants: ["get-task-allow": true],
            allDevices: false, devices: ["00008030-ABCDEF0123456789"], platform: ["watchOS"])
        let result = evaluate(value, target: target("com.example.app.watch", path: "Watch/Watch.app", platform: "watchOS", parent: "com.example.app"),
            device: "00008030-ABCDEF0123456789")
        XCTAssertEqual(result.status, .ambiguous)
        XCTAssertTrue(result.issues.contains { $0.code == .device })
    }

    func testStoreDistributionAndWrongPlatformAreUnsupportedForDirectDeviceSigning() throws {
        let store = try candidate(team + ".com.example.app", id: "store", allDevices: false)
        XCTAssertEqual(evaluate(store).status, .unsupported)
        XCTAssertTrue(evaluate(store).issues.contains { $0.code == .mode })
        let mac = try candidate(team + ".com.example.app", id: "mac", platform: ["OSX"])
        XCTAssertEqual(evaluate(mac).status, .unsupported)
        XCTAssertTrue(evaluate(mac).issues.contains { $0.code == .platform })
    }

    func testLegacyApplicationPrefixIsNotConfusedWithTheCertificateTeam() throws {
        let legacy = "LEGACY0001"
        let value = try candidate(legacy + ".com.example.app", id: "legacy", prefix: legacy)
        let result = evaluate(value)
        XCTAssertEqual(result.status, .valid)
        XCTAssertEqual(result.entitlements["application-identifier"] as? String, legacy + ".com.example.app")
        XCTAssertEqual(result.entitlements["com.apple.developer.team-identifier"] as? String, team)
    }

    func testConcreteUserMismatchesNeverRenameTheTargetToFitAProfile() throws {
        let value = try candidate("N2998T85B9.app.vanilla7419.emerald5335", id: "incompatible", prefix: "N2998T85B9")
        for identifier in ["app.aidoku.Aidoku", "app.batsign.ios", "app.batsign.ios.status"] {
            let result = evaluate(value, target: target(identifier))
            XCTAssertEqual(result.status, .invalid)
            XCTAssertEqual(result.target.bundleIdentifier, identifier)
            XCTAssertTrue(result.issues.contains { $0.code == .identifier })
        }
    }

    func testRequiredCapabilitiesAreNotSilentlyCopiedFromProfileOrRemoved() throws {
        let requested: [String: Any] = ["aps-environment": "production", "com.apple.security.application-groups": ["group.example.shared"],
            "dynamic-codesigning": true]
        let value = try candidate(team + ".com.example.app", id: "limited", grants: ["unrequested-capability": true])
        let result = evaluate(value, target: target(entitlements: requested))
        XCTAssertEqual(result.status, .invalid)
        XCTAssertTrue(MachOEntitlements.equivalent(requested,
            result.entitlements.filter { requested[$0.key] != nil }))
        XCTAssertNil(result.entitlements["unrequested-capability"])
        XCTAssertEqual(Set(result.issues.filter { $0.code == .entitlement }.map { issue in
            requested.keys.first(where: { issue.detail.contains($0) }) ?? ""
        }), Set(requested.keys))
    }

    func testNestedNamespaceMismatchIsMandatoryEvenWhenAProfileCoversIt() throws {
        let value = try candidate(team + ".com.other.widget", id: "wrong-parent")
        let result = evaluate(value, target: target("com.other.widget", path: "PlugIns/Widget.appex", parent: "com.example.app"))
        XCTAssertEqual(result.status, .invalid)
        XCTAssertTrue(result.issues.contains { $0.code == .structure })
    }

    func testBooleanAndIntegerEntitlementEvidenceAreNotInterchangeable() {
        XCTAssertFalse(ProfileEntitlementAuthorization.allows(NSNumber(value: 1), granted: NSNumber(value: true), key: "flag"))
        XCTAssertFalse(ProfileEntitlementAuthorization.allows(NSNumber(value: false), granted: NSNumber(value: 0), key: "flag"))
        XCTAssertFalse(MachOEntitlements.equivalent(["flag": false], ["flag": 0]))
        XCTAssertTrue(ProfileEntitlementAuthorization.allows(false, granted: true, key: "flag"))
        XCTAssertFalse(ProfileEntitlementAuthorization.allows(true, granted: false, key: "flag"))
    }

    func testArraysAndDictionariesAreTypedSubsetsNotStringDescriptions() {
        XCTAssertTrue(ProfileEntitlementAuthorization.allows(["a"], granted: ["a", "b"], key: "unknown"))
        XCTAssertFalse(ProfileEntitlementAuthorization.allows([1], granted: [true], key: "unknown"))
        XCTAssertFalse(ProfileEntitlementAuthorization.allows(["x": 1], granted: ["x": true], key: "unknown"))
        XCTAssertFalse(ProfileEntitlementAuthorization.allows(["a", "missing"], granted: ["a"], key: "unknown"))
    }

    func testOnlyDocumentedGrantWildcardsExpandAndRequestedKeychainWildcardsReject() {
        XCTAssertTrue(ProfileEntitlementAuthorization.allows([team + ".com.example.shared"], granted: [team + ".*"], key: "keychain-access-groups"))
        XCTAssertFalse(ProfileEntitlementAuthorization.allows([team + ".*"], granted: [team + ".*"], key: "keychain-access-groups"))
        XCTAssertFalse(ProfileEntitlementAuthorization.allows("group.example.shared", granted: "group.example.*", key: "com.apple.security.application-groups"))
    }

    func testUnsupportedTypesAndExcessiveEntitlementTreesFailClosed() {
        XCTAssertTrue(ProfileEntitlementAuthorization.isSupportedByNativeEncoder(["zero": 0, "negative": -129, "flag": false]))
        for value in [Data([1]), now, 1.2, UInt64.max] as [Any] {
            XCTAssertFalse(ProfileEntitlementAuthorization.isSupportedByNativeEncoder(["value": value]))
        }
        var nested: Any = "leaf"
        for _ in 0..<34 { nested = [nested] }
        XCTAssertFalse(ProfileEntitlementAuthorization.isBoundedPropertyList(nested))
        XCTAssertFalse(ProfileEntitlementAuthorization.isBoundedPropertyList([String(repeating: "x", count: 257): true]))
    }

    func testPreferencesRoundTripOnlyPublicCertificateAndProfileIdentifiers() throws {
        let value = ComponentSigningPreference(certificateFingerprint: "public-sha256", profileUUID: UUID().uuidString)
        let data = try JSONEncoder().encode(value), text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertEqual(try JSONDecoder().decode(ComponentSigningPreference.self, from: data), value)
        XCTAssertFalse(text.contains("password")); XCTAssertFalse(text.contains("privateKey")); XCTAssertFalse(text.contains("p12"))
    }
}
