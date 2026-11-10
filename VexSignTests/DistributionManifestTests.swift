import CryptoKit
import Foundation
import XCTest
@testable import VexSign

final class DistributionManifestTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let keyID = "test-key"
    private let applicationIdentifier = "com.vexsign.app"

    func testVerifiesSignedReleaseManifestBeforeReturningPayload() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let verifier = ReleaseManifestVerifier(
            trustedPublicKeys: [keyID: privateKey.publicKey.rawRepresentation],
            expectedApplicationIdentifier: applicationIdentifier
        )
        let encoded = try signedEnvelope(manifest(), key: privateKey)

        let result = try verifier.verify(envelopeData: encoded, supportedOSVersion: "17.0", now: now)
        XCTAssertEqual(result.applicationIdentifier, applicationIdentifier)
        XCTAssertEqual(result.version, "1.4.2")
        XCTAssertEqual(result.channel, .stable)
    }

    func testRejectsTamperedPayloadAndUnknownKey() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let originalEnvelope = try signedEnvelope(manifest(), key: privateKey)
        let envelope = try JSONDecoder().decode(SignedReleaseManifest.self, from: originalEnvelope)
        let unknownKeyEnvelope = SignedReleaseManifest(
            schemaVersion: envelope.schemaVersion,
            algorithm: envelope.algorithm,
            keyID: "untrusted",
            payloadBase64: envelope.payloadBase64,
            signatureBase64: envelope.signatureBase64
        )
        let verifier = ReleaseManifestVerifier(
            trustedPublicKeys: [keyID: privateKey.publicKey.rawRepresentation],
            expectedApplicationIdentifier: applicationIdentifier
        )
        let encodedUnknownKey = try JSONEncoder().encode(unknownKeyEnvelope)
        XCTAssertThrowsError(
            try verifier.verify(envelopeData: encodedUnknownKey, supportedOSVersion: "17.0", now: now)
        ) {
            XCTAssertEqual($0 as? ReleaseManifestFailure, .unknownSigningKey)
        }

        let payload = try XCTUnwrap(Data(base64Encoded: envelope.payloadBase64))
        let tamperedEnvelope = SignedReleaseManifest(
            schemaVersion: envelope.schemaVersion,
            algorithm: envelope.algorithm,
            keyID: keyID,
            payloadBase64: Data(payload + Data([0])).base64EncodedString(),
            signatureBase64: envelope.signatureBase64
        )
        let encodedTamperedPayload = try JSONEncoder().encode(tamperedEnvelope)
        XCTAssertThrowsError(
            try verifier.verify(envelopeData: encodedTamperedPayload, supportedOSVersion: "17.0", now: now)
        ) {
            XCTAssertEqual($0 as? ReleaseManifestFailure, .invalidSignature)
        }
    }

    func testRejectsInvalidMetadataAndExpiredOrIncompatibleRelease() throws {
        let verifier = ReleaseManifestVerifier(
            trustedPublicKeys: [:],
            expectedApplicationIdentifier: applicationIdentifier
        )
        XCTAssertThrowsError(
            try verifier.validate(
                manifest(applicationIdentifier: "com.other.app"),
                supportedOSVersion: "17.0",
                now: now
            )
        ) {
            XCTAssertEqual($0 as? ReleaseManifestFailure, .invalidApplicationIdentifier)
        }
        XCTAssertThrowsError(try verifier.validate(manifest(ipaSHA256: "nope"), supportedOSVersion: "17.0", now: now)) {
            XCTAssertEqual($0 as? ReleaseManifestFailure, .invalidSHA256)
        }
        XCTAssertThrowsError(try verifier.validate(manifest(expiresAt: now), supportedOSVersion: "17.0", now: now)) {
            XCTAssertEqual($0 as? ReleaseManifestFailure, .expired)
        }
        XCTAssertThrowsError(
            try verifier.validate(
                manifest(minimumOSVersion: "18.0"),
                supportedOSVersion: "17.0",
                now: now
            )
        ) {
            XCTAssertEqual($0 as? ReleaseManifestFailure, .unsupportedMinimumOS)
        }
        let insecureURL = URL(string: "http://example.com/app.ipa")!
        XCTAssertThrowsError(
            try verifier.validate(
                manifest(downloadURL: insecureURL),
                supportedOSVersion: "17.0",
                now: now
            )
        ) {
            XCTAssertEqual($0 as? ReleaseManifestFailure, .invalidURL)
        }
        XCTAssertThrowsError(
            try verifier.validate(
                manifest(signingMethod: .appStore),
                supportedOSVersion: "17.0",
                now: now
            )
        ) {
            XCTAssertEqual($0 as? ReleaseManifestFailure, .invalidSigningClass)
        }
    }

    func testUnsignedBuildCanBeAuthenticatedForDownloadButNotInstallation() throws {
        let verifier = ReleaseManifestVerifier(trustedPublicKeys: [:], expectedApplicationIdentifier: applicationIdentifier)
        XCTAssertNoThrow(
            try verifier.validate(
                manifest(signingMethod: .artifactDownload, signingClass: .unsigned),
                supportedOSVersion: "17.0",
                now: now
            )
        )
        let eligibility = DistributionEligibilityService().evaluate(
            method: .directOTA,
            signingClass: .unsigned,
            context: .init()
        )
        XCTAssertEqual(eligibility.state, .ineligible(reason: .otaRequiresEligibleSignedArtifact))
    }

    func testHashesArtifactInBoundedChunksAndChecksExpectedDigest() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("hello".utf8).write(to: file)
        let digest = try ArtifactHashVerifier.sha256(fileURL: file, chunkSize: 2)
        XCTAssertEqual(digest, "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
        XCTAssertEqual(try ArtifactHashVerifier.verify(fileURL: file, expectedSHA256: digest), digest)
        XCTAssertThrowsError(
            try ArtifactHashVerifier.verify(
                fileURL: file,
                expectedSHA256: String(repeating: "0", count: 64)
            )
        )
    }

    func testEligibilityDoesNotTreatDistributionClassesAsInterchangeable() {
        let service = DistributionEligibilityService()
        let context = DistributionEligibilityContext(
            registeredDevice: true,
            enterpriseProgramEligible: true,
            personalTeamProvisioningValid: true,
            profileNotExpired: true,
            bundleIdentifierMatches: true,
            deviceIncludedInProfile: true
        )
        XCTAssertEqual(service.evaluate(method: .adHoc, signingClass: .enterprise, context: context).state,
                       .ineligible(reason: .unsupportedArtifactSigningClass))
        XCTAssertEqual(service.evaluate(method: .directOTA, signingClass: .appStore, context: context).state,
                       .ineligible(reason: .otaRequiresEligibleSignedArtifact))
        XCTAssertEqual(service.evaluate(method: .directOTA, signingClass: .adHoc, context: context).state, .eligible)
        XCTAssertEqual(service.evaluate(method: .testFlight, signingClass: .appStore, context: .init()).state,
                       .requiresExternalFlow(reason: .testFlightNotPublished))
    }

    private func manifest(
        applicationIdentifier: String = "com.vexsign.app",
        downloadURL: URL = URL(string: "https://github.com/raynmahbub/VexSign/releases/download/v1.4.2/VexSign.ipa")!,
        ipaSHA256: String = String(repeating: "a", count: 64),
        expiresAt: Date? = nil,
        minimumOSVersion: String = "17.0",
        signingMethod: DistributionMethod = .directOTA,
        signingClass: ArtifactSigningClass = .adHoc
    ) -> ReleaseManifest {
        ReleaseManifest(
            schemaVersion: 1,
            applicationIdentifier: applicationIdentifier,
            version: "1.4.2",
            buildNumber: "1020304",
            channel: .stable,
            minimumOSVersion: minimumOSVersion,
            downloadURL: downloadURL,
            ipaSHA256: ipaSHA256,
            releaseNotesURL: URL(string: "https://github.com/raynmahbub/VexSign/releases/tag/v1.4.2"),
            createdAt: now.addingTimeInterval(-60),
            expiresAt: expiresAt ?? now.addingTimeInterval(3600),
            signing: ReleaseSigningInformation(
                distributionMethod: signingMethod,
                signingClass: signingClass,
                teamIdentifier: nil,
                certificateSHA256: nil
            )
        )
    }

    private func signedEnvelope(_ manifest: ReleaseManifest, key: Curve25519.Signing.PrivateKey) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(manifest)
        let envelope = SignedReleaseManifest(
            schemaVersion: 1,
            algorithm: "Ed25519",
            keyID: keyID,
            payloadBase64: payload.base64EncodedString(),
            signatureBase64: try key.signature(for: payload).base64EncodedString()
        )
        return try JSONEncoder().encode(envelope)
    }
}
