import Foundation
import XCTest
@testable import NativeSigningLinkSmoke

/// Synthetic plist/policy fixtures ONLY. No real CMS, certificate, Apple server,
/// Keychain or signature verification is performed by these coding-phase cases.
final class NativeProvisioningProfileTests: XCTestCase {
    private static let now = Date(timeIntervalSince1970: 10_000)
    private static let team = "ABCDE12345"
    private static let bundle = "com.example.fixture"
    private static let udid = "0000ABCD-0011223344556677"
    private static let certificate = Data([0x30, 0x01, 0x00]) // NOT a real X.509 cert
    private static let uuid = UUID(uuidString: "12345678-1234-1234-1234-123456789012")!
    private struct FixtureVerifier: NativeProfileCMSVerifying {
        let payload: Data
        func verifyAppleProvisioningCMS(_ cms: Data, now: Date) async throws -> Data { payload }
    }
    private struct RejectingVerifier: NativeProfileCMSVerifying {
        func verifyAppleProvisioningCMS(_ cms: Data, now: Date) async throws -> Data {
            throw NSError(domain: "synthetic private response", code: 1)
        }
    }
    private static func request(expectedUUID: UUID? = nil) throws -> NativeProfileValidationRequest {
        try .init(teamIdentifier: team, bundleIdentifier: bundle, deviceIdentifier: udid,
                  certificateDER: certificate, expectedUUID: expectedUUID)
    }
    private static func profile() -> [String: Any] {
        ["Version": 1, "UUID": uuid.uuidString, "CreationDate": now.addingTimeInterval(-60),
         "ExpirationDate": now.addingTimeInterval(3600), "Platform": ["iOS"],
         "TeamIdentifier": [team], "ApplicationIdentifierPrefix": [team],
         "ProvisionedDevices": [udid], "DeveloperCertificates": [certificate],
         "Entitlements": ["application-identifier": team + "." + bundle,
                          "com.apple.developer.team-identifier": team,
                          "get-task-allow": true, "keychain-access-groups": [team + ".*"]]]
    }
    private static func payload(_ root: [String: Any], format: PropertyListSerialization.PropertyListFormat = .xml) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: root, format: format, options: 0)
    }
    private static func constraints(_ root: [String: Any]) throws -> NativeProfileConstraintSummary {
        try NativeProvisioningProfileValidator.validatePayloadConstraints(payload(root), request: request(), now: now)
    }

    func testMatchingConstraintsNarrowWildcardKeychainGrant() throws {
        let result = try Self.constraints(Self.profile())
        XCTAssertEqual(result.uuid, Self.uuid)
        XCTAssertEqual(result.keychainAccessGroup, Self.team + "." + Self.bundle)
        XCTAssertFalse(result.keychainAccessGroup.contains("*"))
    }

    func testPlainPlistCannotPassDefaultCMSGate() async throws {
        do {
            _ = try await NativeProvisioningProfileValidator().validate(cms: Self.payload(Self.profile()), request: Self.request(), now: Self.now)
            XCTFail("No production verifier is installed")
        } catch { XCTAssertEqual(error as? NativeProfileValidationError, .cmsVerificationUnavailable) }
    }

    func testInjectedFixtureExercisesGateButDoesNotProveCMSTrust() async throws {
        let cms = Data("SYNTHETIC CMS ENVELOPE".utf8)
        let validator = NativeProvisioningProfileValidator(verifier: FixtureVerifier(payload: try Self.payload(Self.profile())))
        let result = try await validator.validate(cms: cms, request: Self.request(expectedUUID: Self.uuid), now: Self.now)
        XCTAssertEqual(result.cmsSHA256, NativeSigningIdentityOwner.hash(cms))
        XCTAssertEqual(result.constraints.uuid, Self.uuid)
        XCTAssertEqual(result.description, "NativeAuthenticatedProvisioningProfile(redacted)")
    }

    func testVerifierFailureIsSanitized() async throws {
        do {
            _ = try await NativeProvisioningProfileValidator(verifier: RejectingVerifier()).validate(
                cms: Data([1]), request: Self.request(), now: Self.now)
            XCTFail("Bad CMS")
        } catch { XCTAssertEqual(error as? NativeProfileValidationError, .cmsRejected) }
    }

    func testNonFiniteClockAndExpiredOrFutureDatesAreRejected() throws {
        let raw = try Self.payload(Self.profile())
        XCTAssertThrowsError(try NativeProvisioningProfileValidator.validatePayloadConstraints(raw, request: Self.request(), now: Date(timeIntervalSince1970: .nan)))
        for field in ["CreationDate", "ExpirationDate"] {
            var root = Self.profile()
            root[field] = field == "CreationDate" ? Self.now.addingTimeInterval(1) : Self.now
            XCTAssertThrowsError(try Self.constraints(root)) { XCTAssertEqual($0 as? NativeProfileValidationError, .expired) }
        }
    }

    func testTeamAndPrefixMustBothMatchExactly() throws {
        for key in ["TeamIdentifier", "ApplicationIdentifierPrefix"] {
            for value in [["OTHER12345"], [Self.team, "OTHER12345"], []] {
                var root = Self.profile(); root[key] = value
                XCTAssertThrowsError(try Self.constraints(root)) { XCTAssertEqual($0 as? NativeProfileValidationError, .contextMismatch) }
            }
        }
    }

    func testExpectedUUIDCannotBeSubstituted() throws {
        XCTAssertThrowsError(try NativeProvisioningProfileValidator.validatePayloadConstraints(
            Self.payload(Self.profile()), request: Self.request(expectedUUID: UUID()), now: Self.now)) {
            XCTAssertEqual($0 as? NativeProfileValidationError, .contextMismatch)
        }
    }

    func testDeviceMustBeExplicitPresentAndUnique() throws {
        for devices in [[], ["11111111-0011223344556677"], [Self.udid, Self.udid.lowercased()], ["vendor-identifier"]] {
            var root = Self.profile(); root["ProvisionedDevices"] = devices
            XCTAssertThrowsError(try Self.constraints(root)) { XCTAssertEqual($0 as? NativeProfileValidationError, .contextMismatch) }
        }
        var root = Self.profile(); root["ProvisionedDevices"] = [Self.udid.lowercased()]
        XCTAssertNoThrow(try Self.constraints(root))
    }

    func testCertificateMustBeExactOwnedDERAndInventoryUnique() throws {
        for certificates in [[], [Data([1, 2, 3])], [Self.certificate, Self.certificate]] {
            var root = Self.profile(); root["DeveloperCertificates"] = certificates
            XCTAssertThrowsError(try Self.constraints(root)) { XCTAssertEqual($0 as? NativeProfileValidationError, .certificateMismatch) }
        }
    }

    func testStoreEnterpriseAndNonIOSProfilesFailClosed() throws {
        var enterprise = Self.profile(); enterprise["ProvisionsAllDevices"] = true
        XCTAssertThrowsError(try Self.constraints(enterprise))
        enterprise["ProvisionsAllDevices"] = 0 // numeric zero is not Boolean false
        XCTAssertThrowsError(try Self.constraints(enterprise))
        var store = Self.profile(); store.removeValue(forKey: "ProvisionedDevices")
        XCTAssertThrowsError(try Self.constraints(store))
        for platform in [["macOS"], ["iOS", "tvOS"], []] {
            var root = Self.profile(); root["Platform"] = platform
            XCTAssertThrowsError(try Self.constraints(root))
        }
    }

    func testEntitlementsCannotBroadenToWildcardForeignGroupOrExtraCapability() throws {
        let changes: [(String, Any)] = [
            ("application-identifier", Self.team + ".*"),
            ("application-identifier", Self.team + ".com.example.other"),
            ("com.apple.developer.team-identifier", "OTHER12345"),
            ("get-task-allow", false), ("get-task-allow", 1),
            ("keychain-access-groups", ["OTHER12345.*"]),
            ("aps-environment", "development"), ("beta-reports-active", true)
        ]
        for (key, value) in changes {
            var root = Self.profile()
            var entitlements = root["Entitlements"] as! [String: Any]
            entitlements[key] = value; root["Entitlements"] = entitlements
            XCTAssertThrowsError(try Self.constraints(root)) { XCTAssertEqual($0 as? NativeProfileValidationError, .unsupportedEntitlements) }
        }
    }

    func testMalformedVersionAndMissingRequiredEntitlementsAreRejected() throws {
        for version in [true, 1.0, "1"] as [Any] {
            var root = Self.profile(); root["Version"] = version
            XCTAssertThrowsError(try Self.constraints(root))
        }
        var root = Self.profile(); root["Entitlements"] = [:] as [String: Any]
        XCTAssertThrowsError(try Self.constraints(root))
    }

    func testBinaryAndXMLPayloadPoliciesAgree() throws {
        let root = Self.profile(); let request = try Self.request()
        let xml = try NativeProvisioningProfileValidator.validatePayloadConstraints(Self.payload(root), request: request, now: Self.now)
        let binary = try NativeProvisioningProfileValidator.validatePayloadConstraints(Self.payload(root, format: .binary), request: request, now: Self.now)
        XCTAssertEqual(xml, binary)
    }

    func testInputBoundsAndRequestRedaction() async throws {
        let request = try Self.request()
        XCTAssertEqual(request.description, "NativeProfileValidationRequest(redacted)")
        XCTAssertThrowsError(try NativeProvisioningProfileValidator.validatePayloadConstraints(Data(repeating: 0, count: 512 * 1024 + 1), request: request, now: Self.now))
        XCTAssertThrowsError(try NativeProfileValidationRequest(teamIdentifier: Self.team, bundleIdentifier: Self.bundle,
            deviceIdentifier: Self.udid, certificateDER: Data(repeating: 0, count: 64 * 1024 + 1)))
        do {
            _ = try await NativeProvisioningProfileValidator().validate(cms: Data(repeating: 0, count: 1024 * 1024 + 1), request: request, now: Self.now)
            XCTFail("Bound CMS input before invoking verifier")
        } catch { XCTAssertEqual(error as? NativeProfileValidationError, .malformedProfile) }
    }
}
