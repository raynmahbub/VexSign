import Foundation
import XCTest
@testable import NativeSigningLinkSmoke

/// DER PURPOSE parsing fixtures only. These intentionally have no valid SPKI or
/// certificate signature and cannot become Apple trust/key/revocation evidence.
final class NativeDevelopmentCertificateTests: XCTestCase {
    private static let team = "ABCDE12345"
    private static let bundle = "com.example.fixture"
    private static let device = "0000ABCD-0011223344556677"
    private static let now = Date(timeIntervalSince1970: 10_000)
    private static func tlv(_ tag: UInt8, _ value: Data) -> Data {
        var result = Data([tag]); var size = value.count
        if size < 128 { result.append(UInt8(size)) }
        else {
            var bytes: [UInt8] = []
            while size > 0 { bytes.insert(UInt8(size & 255), at: 0); size >>= 8 }
            result.append(0x80 | UInt8(bytes.count)); result.append(contentsOf: bytes)
        }
        result.append(value); return result
    }
    private static func seq(_ parts: [Data]) -> Data { tlv(0x30, parts.reduce(Data(), +)) }
    private static func certificate(team: String = NativeDevelopmentCertificateTests.team, duplicateOU: Bool = false,
                                    marker: Data = NativeDevelopmentCertificatePurpose.development,
                                    extraEKU: Bool = false, ca: Bool = false, duplicateExtension: Bool = false) -> Data {
        let ou = tlv(0x31, seq([tlv(6, Data([0x55,4,0x0b])), tlv(0x0c, Data(team.utf8))]))
        let subject = seq(duplicateOU ? [ou, ou] : [ou])
        var usage = [tlv(6, NativeDevelopmentCertificatePurpose.codeSigning)]
        if extraEKU { usage.append(tlv(6, Data([0x55,0x1d,0x25,0]))) }
        var fields: [(Data, Data)] = [(marker, Data([5,0])), (NativeDevelopmentCertificatePurpose.eku, seq(usage)),
            (NativeDevelopmentCertificatePurpose.keyUsage, Data([3,2,7,0x80])), (NativeDevelopmentCertificatePurpose.basicConstraints, ca ? seq([tlv(1, Data([0xff]))]) : seq([]))]
        if duplicateExtension { fields.append((marker, Data([5,0]))) }
        let extensions = fields.map { seq([tlv(6, $0.0), tlv(4, $0.1)]) }
        let tbs = seq([tlv(0xa0, tlv(2, Data([2]))), tlv(2, Data([1])), seq([]), seq([]), seq([]), subject, seq([]), tlv(0xa3, seq(extensions))])
        return seq([tbs, seq([]), tlv(3, Data([0,0]))])
    }
    private static func owner() throws -> NativeSigningIdentityOwner {
        try .init(accountIdentifier: "123", dsid: "123", teamIdentifier: team)
    }
    func testDevelopmentPurposeParsingIsNotCertificateTrust() throws {
        let der = Self.certificate()
        XCTAssertNoThrow(try NativeDevelopmentCertificatePurpose.requireDevelopment(der, teamIdentifier: Self.team))
        XCTAssertEqual(try NativeDevelopmentCertificatePurpose.fields(der).publicKey, Data([0x30,0]))
    }
    func testExactSingleTeamOUIsRequired() {
        for der in [Self.certificate(team: "ZZZZZ99999"), Self.certificate(duplicateOU: true)] {
            XCTAssertThrowsError(try NativeDevelopmentCertificatePurpose.requireDevelopment(der, teamIdentifier: Self.team)) {
                XCTAssertEqual($0 as? NativeDevelopmentCertificateError, .teamMismatch)
            }
        }
    }
    func testDistributionAnyPurposeAndCALeavesCannotStandInForDevelopment() {
        var distribution = NativeDevelopmentCertificatePurpose.development; distribution[distribution.count - 1] = 4
        for der in [Self.certificate(marker: distribution), Self.certificate(extraEKU: true), Self.certificate(ca: true)] {
            XCTAssertThrowsError(try NativeDevelopmentCertificatePurpose.requireDevelopment(der, teamIdentifier: Self.team))
        }
    }
    func testDuplicateExtensionsAndMalformedDERReject() {
        for der in [Self.certificate(duplicateExtension: true), Data(Self.certificate().dropLast()), Self.certificate() + Data([0])] {
            XCTAssertThrowsError(try NativeDevelopmentCertificatePurpose.requireDevelopment(der, teamIdentifier: Self.team))
        }
    }
    func testWWDRMarkerDoesNotAcceptDevelopmentMarker() {
        XCTAssertNoThrow(try NativeDevelopmentCertificatePurpose.requireWWDR(Self.certificate(marker: NativeDevelopmentCertificatePurpose.wwdr)))
        XCTAssertThrowsError(try NativeDevelopmentCertificatePurpose.requireWWDR(Self.certificate()))
    }
    func testTrustVerifierRejectsInvalidCertificateWithoutProducingEvidence() async throws {
        do {
            _ = try await NativeDevelopmentCertificateVerifier().evaluate(owner: Self.owner(), contextID: UUID(),
                certificateDER: Data([1]), issuerCertificates: [], now: Self.now, checkCurrent: {})
            XCTFail("Invalid X509 cannot become trust evidence")
        } catch { XCTAssertEqual(error as? NativeDevelopmentCertificateError, .purposeRejected) }
    }
    func testDuplicateCertificateInputsAndNonFiniteTimeRejectBeforeTrust() async throws {
        for issuers in [[Data([1])], []] {
            do {
                _ = try await NativeDevelopmentCertificateVerifier().evaluate(owner: Self.owner(), contextID: UUID(),
                    certificateDER: Data([1]), issuerCertificates: issuers,
                    now: issuers.isEmpty ? Date(timeIntervalSince1970: .nan) : Self.now, checkCurrent: {})
                XCTFail("Invalid inputs")
            } catch { XCTAssertEqual(error as? NativeDevelopmentCertificateError, .invalidInput) }
        }
    }
    func testContextFailureBlocksTrustAndIsSanitized() async throws {
        do {
            _ = try await NativeDevelopmentCertificateVerifier().evaluate(owner: Self.owner(), contextID: UUID(),
                certificateDER: Data([1]), issuerCertificates: [], now: Self.now,
                checkCurrent: { throw NSError(domain: "private fixture response", code: 1) })
            XCTFail("No current authority")
        } catch { XCTAssertEqual(error as? NativeDevelopmentCertificateError, .contextChanged) }
    }

    private struct FixtureCMS: NativeProfileCMSVerifying {
        let payload: Data
        func verifyAppleProvisioningCMS(_ cms: Data, now: Date) async throws -> Data { payload }
    }
    private struct Lifetime: NativeAccountBackendLifetime {}
    private static func profile() async throws -> (NativeAuthenticatedProvisioningProfile, NativeProvisioningProfileValidator) {
        let root: [String: Any] = ["Version": 1, "UUID": UUID().uuidString, "CreationDate": now.addingTimeInterval(-1),
            "ExpirationDate": now.addingTimeInterval(600), "Platform": ["iOS"], "TeamIdentifier": [team],
            "ApplicationIdentifierPrefix": [team], "ProvisionedDevices": [device], "DeveloperCertificates": [Data([1])],
            "Entitlements": ["application-identifier": team + "." + bundle, "com.apple.developer.team-identifier": team,
                "get-task-allow": true, "keychain-access-groups": [team + ".*"]]]
        let payload = try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
        let validator = NativeProvisioningProfileValidator(verifier: FixtureCMS(payload: payload))
        let request = try NativeProfileValidationRequest(teamIdentifier: team, bundleIdentifier: bundle, deviceIdentifier: device, certificateDER: Data([1]))
        return (try await validator.validate(cms: Data("SYNTHETIC NOT CMS".utf8), request: request, now: now), validator)
    }
    func testHandoffDefaultCMSGateRunsBeforeArchiveOrCallbacks() async throws {
        let (profile, _) = try await Self.profile()
        let target = try NativeAccountProfileTarget(identityID: UUID(), bundleIdentifier: Self.bundle, deviceIdentifier: Self.device,
            registeredAppID: "APP1", registeredDeviceID: "DEVICE1")
        do {
            _ = try await NativeProtectedSigningHandoffFactory(clock: { Self.now }).prepare(archive: Data(), owner: Self.owner(), contextID: UUID(),
                target: target, profile: profile, issuerCertificates: [], authorityExpiresAt: Self.now.addingTimeInterval(60), lifetime: Lifetime(),
                ownedIdentity: { XCTFail("No identity access before CMS gate"); throw NativeSigningIdentityError.invalidRecord },
                checkAuthority: { XCTFail("No authority callback before CMS gate") })
            XCTFail("Default verifier unavailable")
        } catch { XCTAssertEqual(error as? NativeProfileValidationError, .cmsVerificationUnavailable) }
    }
    func testHandoffRejectsChangedIdentityBeforeArchiveScan() async throws {
        let (profile, validator) = try await Self.profile()
        let target = try NativeAccountProfileTarget(identityID: UUID(), bundleIdentifier: Self.bundle, deviceIdentifier: Self.device,
            registeredAppID: "APP1", registeredDeviceID: "DEVICE1")
        let other = NativeOwnedProfileIdentity(identityID: UUID(), certificateIdentifier: "CERT1", validation:
            try .init(teamIdentifier: Self.team, bundleIdentifier: Self.bundle, deviceIdentifier: Self.device, certificateDER: Data([1])))
        do {
            _ = try await NativeProtectedSigningHandoffFactory(validator: validator, clock: { Self.now }).prepare(archive: Data(),
                owner: Self.owner(), contextID: UUID(), target: target, profile: profile, issuerCertificates: [],
                authorityExpiresAt: Self.now.addingTimeInterval(60), lifetime: Lifetime(), ownedIdentity: { other }, checkAuthority: {})
            XCTFail("Changed identity")
        } catch { XCTAssertEqual(error as? NativeSigningAcceptanceError, .profileMismatch) }
    }
}
