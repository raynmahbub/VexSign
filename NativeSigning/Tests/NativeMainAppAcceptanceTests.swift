import Foundation
import XCTest
@testable import NativeSigningLinkSmoke

/// Synthetic main-file inspection/policy only. No runnable IPA, genuine CMS,
/// original code-signature trust, certificate trust, key or signing operation.
final class NativeMainAppAcceptanceTests: XCTestCase {
    private static let team = "ABCDE12345"
    private static let bundle = "com.example.fixture"
    private static let device = "0000ABCD-0011223344556677"
    private static let now = Date(timeIntervalSince1970: 10_000)
    private static func le(_ value: Int) -> Data { Data((0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
    private static func be(_ value: Int) -> Data { Data((0..<4).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
    private static func plist(_ root: [String: Any], binary: Bool = false) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: root, format: binary ? .binary : .xml, options: 0)
    }
    private static func info(_ changes: [String: Any] = [:], binary: Bool = false) throws -> Data {
        var root: [String: Any] = ["CFBundleIdentifier": bundle, "CFBundleExecutable": "Fixture",
            "CFBundlePackageType": "APPL", "CFBundleSupportedPlatforms": ["iPhoneOS"]]
        root.merge(changes) { _, new in new }; return try plist(root, binary: binary)
    }
    private static func superblob(slot: Int = 5, magic: Int = 0xfade7171, xml: Data) -> Data {
        let child = be(magic) + be(8 + xml.count) + xml
        return be(0xfade0cc0) + be(20 + child.count) + be(1) + be(slot) + be(20) + child
    }
    private static func executable(signature: Data? = nil, cryptID: Int? = nil) -> Data {
        // Synthetic segment metadata, not a complete runnable executable.
        var commands = le(0x19) + le(72) + Data(repeating: 0, count: 64)
        if let cryptID { commands += le(0x2c) + le(24) + le(0) + le(0) + le(cryptID) + le(0) }
        let count = 1 + (cryptID == nil ? 0 : 1) + (signature == nil ? 0 : 1)
        if let signature { commands += le(0x1d) + le(16) + le(32 + commands.count + 16) + le(signature.count) }
        let header = le(0xfeedfacf) + le(0x0100000c) + le(0) + le(2) + le(count) + le(commands.count) + le(0) + le(0)
        return header + commands + (signature ?? Data())
    }
    func testThinUnsignedHeaderInspectionDoesNotInventEntitlements() throws {
        XCTAssertNil(try NativeMachOInspection.inspect(Self.executable()).entitlementsXML)
    }
    func testEncryptedExecutableIsRejectedWithoutDecryption() {
        XCTAssertThrowsError(try NativeMachOInspection.inspect(Self.executable(cryptID: 1))) {
            XCTAssertEqual($0 as? NativeSigningAcceptanceError, .encryptedExecutable)
        }
    }
    func testUnsupportedArchitectureAndMalformedCommandsFailClosed() {
        var fat = Self.executable(); fat.replaceSubrange(0..<4, with: [0xca,0xfe,0xba,0xbe])
        XCTAssertThrowsError(try NativeMachOInspection.inspect(fat))
        var bad = Self.executable(); bad[36] = 7
        XCTAssertThrowsError(try NativeMachOInspection.inspect(bad))
        XCTAssertThrowsError(try NativeMachOInspection.inspect(Data(Self.executable().dropLast())))
    }
    func testXMLClaimsAreExtractedButDERClaimsAreNotSilentlyDropped() throws {
        let xml = try Self.plist(["get-task-allow": false])
        XCTAssertEqual(try NativeMachOInspection.inspect(Self.executable(signature: Self.superblob(xml: xml))).entitlementsXML, xml)
        XCTAssertThrowsError(try NativeMachOInspection.inspect(Self.executable(signature: Self.superblob(slot: 7, magic: 0xfade7172, xml: Data([0x30,0]))))) {
            XCTAssertEqual($0 as? NativeSigningAcceptanceError, .unsupportedEntitlements)
        }
    }
    func testCodeSignatureOffsetAndDuplicateOrOverlappingSlotsAreRejected() {
        var file = Self.executable(signature: Self.superblob(xml: Data("<?xml broken".utf8)))
        file[112] = 0 // signature points into header
        XCTAssertThrowsError(try NativeMachOInspection.inspect(file))
        let child = Self.be(0xfade0c02) + Self.be(8)
        for slot in [0, 2] {
            let blob = Self.be(0xfade0cc0) + Self.be(36) + Self.be(2) + Self.be(0) + Self.be(28) + Self.be(slot) + Self.be(28) + child
            XCTAssertThrowsError(try NativeMachOInspection.inspect(Self.executable(signature: blob)))
        }
    }
    func testInfoBindsExactExecutableBundleAndDevicePlatform() throws {
        for binary in [false, true] {
            XCTAssertNoThrow(try NativeMainAppAcceptance.validateInfo(Self.info(binary: binary), executableName: "Fixture", bundleIdentifier: Self.bundle))
        }
        let cases: [[String: Any]] = [["CFBundleIdentifier": "com.example.other"], ["CFBundleExecutable": "Other"], ["CFBundleSupportedPlatforms": ["iPhoneSimulator"]], ["NSExtension": [:]]]
        for changes in cases {
            XCTAssertThrowsError(try NativeMainAppAcceptance.validateInfo(Self.info(changes), executableName: "Fixture", bundleIdentifier: Self.bundle))
        }
        XCTAssertThrowsError(try NativeMainAppAcceptance.validateInfo(Self.info(), executableName: "Fixture\n", bundleIdentifier: Self.bundle))
    }
    func testForeignIdentityIsRewrittenWithoutCopyingForeignKeychainAuthority() throws {
        let original = "ZZZZZ99999." + Self.bundle
        let claims = try Self.plist(["application-identifier": original, "com.apple.developer.team-identifier": "ZZZZZ99999",
            "keychain-access-groups": [original], "get-task-allow": false])
        let output = try NativeMainAppAcceptance.signingEntitlements(requestedXML: claims, bundleIdentifier: Self.bundle,
            applicationIdentifier: Self.team + "." + Self.bundle, teamIdentifier: Self.team)
        let decoded = try XCTUnwrap(try PropertyListSerialization.propertyList(from: output, options: [], format: nil) as? [String: Any])
        XCTAssertEqual(decoded["keychain-access-groups"] as? [String], [Self.team + "." + Self.bundle])
        XCTAssertEqual(decoded["get-task-allow"] as? Bool, true)
        XCTAssertFalse(String(decoding: output, as: UTF8.self).contains("ZZZZZ99999"))
    }
    func testUnsupportedCapabilitiesWildcardGroupsAndIntegerBooleansAreRejected() throws {
        let cases: [[String: Any]] = [["aps-environment": "development"], ["com.apple.security.application-groups": ["group.fixture"]],
            ["keychain-access-groups": [Self.team + ".*"]], ["get-task-allow": 1], ["beta-reports-active": true]]
        for claims in cases {
            XCTAssertThrowsError(try NativeMainAppAcceptance.signingEntitlements(requestedXML: Self.plist(claims), bundleIdentifier: Self.bundle,
                applicationIdentifier: Self.team + "." + Self.bundle, teamIdentifier: Self.team))
        }
    }
    func testExternalAndEntityDTDInputsAreRejectedBeforeOSPlistParser() {
        for declaration in ["<!DOCTYPE plist SYSTEM \"https://untrusted.invalid/evil.dtd\">", "<!DOCTYPE plist [<!ENTITY x \"expanded\">]>"] {
            let raw = Data(("<?xml version=\"1.0\"?>" + declaration + "<plist version=\"1.0\"><dict/></plist>").utf8)
            XCTAssertThrowsError(try NativeMainAppAcceptance.validateInfo(raw, executableName: "Fixture", bundleIdentifier: Self.bundle))
        }
    }

    private struct FixtureVerifier: NativeProfileCMSVerifying {
        let payload: Data
        func verifyAppleProvisioningCMS(_ cms: Data, now: Date) async throws -> Data { payload }
    }
    private static func owned(certificate: Data = Data([1]), device: String = NativeMainAppAcceptanceTests.device) throws -> NativeOwnedProfileIdentity {
        .init(identityID: UUID(), certificateIdentifier: "CERT1", validation: try .init(teamIdentifier: team, bundleIdentifier: bundle,
            deviceIdentifier: device, certificateDER: certificate))
    }
    func testCandidateRetainsExactBytesAndBindsAuthenticatedCertificateAndDevice() async throws {
        let owned = try Self.owned(); let request = owned.validation
        let payload = try Self.plist(["Version": 1, "UUID": UUID().uuidString, "CreationDate": Self.now.addingTimeInterval(-1),
            "ExpirationDate": Self.now.addingTimeInterval(3600), "Platform": ["iOS"], "TeamIdentifier": [Self.team],
            "ApplicationIdentifierPrefix": [Self.team], "ProvisionedDevices": [Self.device], "DeveloperCertificates": [Data([1])],
            "Entitlements": ["application-identifier": Self.team + "." + Self.bundle, "com.apple.developer.team-identifier": Self.team,
                "get-task-allow": true, "keychain-access-groups": [Self.team + ".*"]]])
        let profile = try await NativeProvisioningProfileValidator(verifier: FixtureVerifier(payload: payload))
            .validate(cms: Data("SYNTHETIC, NOT A REAL CMS".utf8), request: request, now: Self.now)
        let info = try Self.info(); let executable = Self.executable()
        let candidate = try NativeMainAppAcceptance.candidate(infoPlist: info, executable: executable, executableName: "Fixture", owned: owned, profile: profile, now: Self.now)
        XCTAssertEqual(candidate.executable, executable); XCTAssertEqual(candidate.infoPlist, info)
        XCTAssertEqual(candidate.profile.encodedCMS, profile.encodedCMS)
        XCTAssertEqual(candidate.expiresAt, Self.now.addingTimeInterval(30))
        XCTAssertEqual(profile.certificateSHA256, NativeSigningIdentityOwner.hash(Data([1])))
        XCTAssertEqual(profile.deviceIdentifier, Self.device)
        XCTAssertFalse(candidate.description.contains(Self.bundle))
        for changed in [try Self.owned(certificate: Data([2])), try Self.owned(device: "0000ABCD-0011223344556688")] {
            XCTAssertThrowsError(try NativeMainAppAcceptance.candidate(infoPlist: info, executable: executable, executableName: "Fixture", owned: changed, profile: profile, now: Self.now))
        }
        XCTAssertThrowsError(try NativeMainAppAcceptance.candidate(infoPlist: info, executable: executable, executableName: "Fixture", owned: owned, profile: profile, now: Self.now.addingTimeInterval(3600)))
    }
}
