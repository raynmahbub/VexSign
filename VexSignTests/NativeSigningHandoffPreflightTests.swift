import Foundation
import XCTest
import NativeSigning
@testable import VexSign

@MainActor
final class NativeSigningHandoffPreflightTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let team = "ABCDE12345"
    private let bundle = "com.example.fixture"
    private let device = "0000ABCD-0011223344556677"
    private let profileUUID = UUID(uuidString: "12345678-1234-1234-1234-123456789012")!

    private func identity(
        teamIdentifier: String? = nil,
        phase: NativeSigningIdentityPhase = .certificateRecorded
    ) -> NativeSigningManager.SigningIdentity {
        .init(id: UUID(), identityID: UUID(), teamIdentifier: teamIdentifier ?? team, phase: phase,
              publicKeyHash: "key", csrHash: "csr", certificateHash: "certificate",
              certificateExpiresAt: now.addingTimeInterval(3600))
    }

    private func profile() -> Certificate {
        Certificate(
            AppIDName: "Fixture", ApplicationIdentifierPrefix: [team],
            CreationDate: now.addingTimeInterval(-60), Platform: ["iOS"], IsXcodeManaged: true,
            DeveloperCertificates: [Data([1])], derEncodedProfile: nil, PPQCheck: false,
            Entitlements: [
                "application-identifier": AnyCodable(team + "." + bundle),
                "com.apple.developer.team-identifier": AnyCodable(team),
                "get-task-allow": AnyCodable(true),
                "keychain-access-groups": AnyCodable([team + ".*"]),
            ],
            ExpirationDate: now.addingTimeInterval(3600), Name: "Fixture",
            ProvisionsAllDevices: false, ProvisionedDevices: [device], TeamIdentifier: [team],
            TeamName: "Fixture", TimeToLive: 7, UUID: profileUUID.uuidString, Version: 1
        )
    }

    private func validate(_ profile: Certificate, identity: NativeSigningManager.SigningIdentity? = nil) throws {
        try NativeSigningHandoffPreflight.validate(profile, profileUUID: profileUUID,
            expiresAt: now.addingTimeInterval(3600), teamIdentifier: team,
            identity: identity ?? self.identity(), bundleIdentifier: bundle,
            deviceIdentifier: device, now: now)
    }

    func testExactAuthenticatedTargetPasses() throws {
        try validate(profile())
    }

    func testTargetAndIdentityDriftAreRejectedBeforeImport() {
        var wrongTeam = profile(); wrongTeam.TeamIdentifier = ["OTHER12345"]
        var wrongDevices = profile(); wrongDevices.ProvisionedDevices = ["00008030-001234567890ABCDEF"]
        var allDevices = profile(); allDevices.ProvisionsAllDevices = true
        var wrongBundle = profile()
        wrongBundle.Entitlements?["application-identifier"] = AnyCodable(team + ".com.example.other")
        var missingCertificate = profile(); missingCertificate.DeveloperCertificates = []
        var wrongExpiry = profile(); wrongExpiry.ExpirationDate = now.addingTimeInterval(7200)
        for candidate in [wrongTeam, wrongDevices, allDevices, wrongBundle, missingCertificate, wrongExpiry] {
            XCTAssertThrowsError(try validate(candidate))
        }
        XCTAssertThrowsError(try validate(profile(), identity: identity(teamIdentifier: "OTHER12345")))
        XCTAssertThrowsError(try validate(profile(), identity: identity(phase: .prepared)))
    }

    func testUnsupportedEntitlementsAndMalformedMetadataAreRejected() {
        var debuggingDisabled = profile()
        debuggingDisabled.Entitlements?["get-task-allow"] = AnyCodable(false)
        var wrongGroups = profile()
        wrongGroups.Entitlements?["keychain-access-groups"] = AnyCodable(["OTHER12345.*"])
        var wrongUUID = profile(); wrongUUID.UUID = UUID().uuidString
        var expired = profile(); expired.ExpirationDate = now
        var future = profile(); future.CreationDate = now.addingTimeInterval(1)
        var wrongPlatform = profile(); wrongPlatform.Platform = ["macOS"]
        for candidate in [debuggingDisabled, wrongGroups, wrongUUID, expired, future, wrongPlatform] {
            XCTAssertThrowsError(try validate(candidate))
        }
    }
}
