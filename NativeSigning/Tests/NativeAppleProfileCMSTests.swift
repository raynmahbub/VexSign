import Foundation
import CryptoKit
import Security
import XCTest
@testable import NativeSigningLinkSmoke

/// Deferred fixtures: structural CMS is synthetic (certificate/signature are NOT
/// Apple credentials); ephemeral Security key use occurs only when tests run.
final class NativeAppleProfileCMSTests: XCTestCase {
    private static let payload = Data("synthetic profile payload".utf8)
    private static let oidData = Data([0x2a,0x86,0x48,0x86,0xf7,0x0d,1,7,1])
    private static let oidSigned = Data([0x2a,0x86,0x48,0x86,0xf7,0x0d,1,7,2])
    private static let oidSHA256 = Data([0x60,0x86,0x48,1,0x65,3,4,2,1])
    private static func tlv(_ tag: UInt8, _ content: Data) -> Data {
        var result = Data([tag])
        if content.count < 128 { result.append(UInt8(content.count)) }
        else {
            var size = content.count; var bytes: [UInt8] = []
            while size > 0 { bytes.insert(UInt8(size & 255), at: 0); size >>= 8 }
            result.append(0x80 | UInt8(bytes.count)); result.append(contentsOf: bytes)
        }
        result.append(content); return result
    }
    private static func sequence(_ values: [Data]) -> Data { tlv(0x30, values.reduce(Data(), +)) }
    private static func algorithm(_ oid: Data) -> Data { sequence([tlv(6, oid), tlv(5, Data())]) }
    private static func cms(wrongDigest: Bool = false, duplicateAttribute: Bool = false, detached: Bool = false,
                            weakAlgorithm: Bool = false, duplicateSigner: Bool = false,
                            payload: Data = NativeAppleProfileCMSTests.payload) -> Data {
        let one = tlv(2, Data([1]))
        let sha = algorithm(weakAlgorithm ? Data([0x2b,0x0e,3,2,0x1a]) : oidSHA256)
        let typeAttr = sequence([tlv(6, Data([0x2a,0x86,0x48,0x86,0xf7,0x0d,1,9,3])), tlv(0x31, tlv(6, oidData))])
        let digest = wrongDigest ? Data(repeating: 0, count: 32) : Data(SHA256.hash(data: payload))
        let digestAttr = sequence([tlv(6, Data([0x2a,0x86,0x48,0x86,0xf7,0x0d,1,9,4])), tlv(0x31, tlv(4, digest))])
        var attrs = [typeAttr, digestAttr]; if duplicateAttribute { attrs.append(typeAttr) }
        attrs.sort { $0.lexicographicallyPrecedes($1) }
        let signer = sequence([one, sequence([sequence([]), one]), sha, tlv(0xa0, attrs.reduce(Data(), +)),
            algorithm(Data([0x2a,0x86,0x48,0x86,0xf7,0x0d,1,1,1])), tlv(4, Data(repeating: 0, count: 256))])
        let encapsulated = sequence(detached ? [tlv(6, oidData)] : [tlv(6, oidData), tlv(0xa0, tlv(4, payload))])
        let signed = sequence([one, tlv(0x31, sha), encapsulated, tlv(0xa0, sequence([one])),
                               tlv(0x31, duplicateSigner ? signer + signer : signer)])
        return sequence([tlv(6, oidSigned), tlv(0xa0, signed)])
    }

    func testDetachedCodeRoleIsSeparateAndBindsExternalDirectory() throws {
        let directory = Data(repeating: 3, count: 88)
        let detached = Self.cms(detached: true, payload: directory)
        let parsed = try NativeProfileCMSEnvelope.parseDetachedCodeSignature(detached, codeDirectory: directory)
        XCTAssertEqual(parsed.payload, directory)
        XCTAssertThrowsError(try NativeProfileCMSEnvelope.parse(detached))
        XCTAssertThrowsError(try NativeProfileCMSEnvelope.parseDetachedCodeSignature(Self.cms(payload: directory), codeDirectory: directory))
        XCTAssertThrowsError(try NativeProfileCMSEnvelope.parseDetachedCodeSignature(detached, codeDirectory: Data(repeating: 4, count: 88)))
        XCTAssertThrowsError(try NativeProfileCMSEnvelope.parseDetachedCodeSignature(detached, codeDirectory: Data()))
    }

    func testStructuralDetachedEnvelopeIsNotSignatureEvidence() throws {
        let directory = Data(repeating: 3, count: 88)
        XCTAssertThrowsError(try NativeDetachedCodeSignatureVerifier.verify(cms: Self.cms(detached: true, payload: directory),
            codeDirectory: directory, expectedCertificate: Self.sequence([Self.tlv(2, Data([1]))])))
    }

    func testStructuralEnvelopeBindsDigestAndRestoresSignedSetTag() throws {
        let parsed = try NativeProfileCMSEnvelope.parse(Self.cms())
        XCTAssertEqual(parsed.payload, Self.payload)
        XCTAssertEqual(parsed.signedAttributes.first, 0x31)
        XCTAssertEqual(parsed.signature.count, 256)
        XCTAssertEqual(parsed.certificates.count, 1)
        // This is not an authenticated profile. Fake certs/signatures fail below.
    }

    func testPayloadDigestTamperingAndDuplicateAttributesAreRejected() {
        XCTAssertThrowsError(try NativeProfileCMSEnvelope.parse(Self.cms(wrongDigest: true)))
        XCTAssertThrowsError(try NativeProfileCMSEnvelope.parse(Self.cms(duplicateAttribute: true)))
    }

    func testDetachedWeakAlgorithmAndMultipleSignersAreRejected() {
        XCTAssertThrowsError(try NativeProfileCMSEnvelope.parse(Self.cms(detached: true)))
        XCTAssertThrowsError(try NativeProfileCMSEnvelope.parse(Self.cms(weakAlgorithm: true)))
        XCTAssertThrowsError(try NativeProfileCMSEnvelope.parse(Self.cms(duplicateSigner: true)))
    }

    func testTrailingTruncatedAndOversizeCMSCannotBeAccepted() {
        XCTAssertThrowsError(try NativeProfileCMSEnvelope.parse(Self.cms() + Data([0])))
        XCTAssertThrowsError(try NativeProfileCMSEnvelope.parse(Data(Self.cms().dropLast())))
        XCTAssertThrowsError(try NativeProfileCMSEnvelope.parse(Data(repeating: 0, count: 1024 * 1024 + 1)))
    }

    func testDERIndefiniteNonMinimalAndHighTagFormsAreRejected() {
        let cases: [[UInt8]] = [[0x30,0x80,0,0], [0x30,0x81,1,0], [0x30,0x82,0,0x80], [0x3f,0], [0x30,0x84,0xff,0xff,0xff,0xff]]
        for bytes in cases {
            XCTAssertThrowsError(try NativeProfileDER.one(Data(bytes), tag: 0x30))
        }
    }

    func testSyntheticCertificateCannotBecomeAppleTrustedProfile() async {
        do {
            _ = try await NativeAppleProfileCMSVerifier().verifyAppleProvisioningCMS(Self.cms(), now: Date())
            XCTFail("Structural parse does not grant Apple trust")
        } catch { XCTAssertEqual(error as? NativeProfileValidationError, .cmsRejected) }
    }

    func testNonFiniteTrustTimeIsRejected() async {
        do {
            _ = try await NativeAppleProfileCMSVerifier().verifyAppleProvisioningCMS(Self.cms(), now: Date(timeIntervalSince1970: .nan))
            XCTFail("Finite current time required")
        } catch { XCTAssertEqual(error as? NativeProfileValidationError, .cmsRejected) }
    }

    // MARK: - Externally generated fixture
    //
    // Every other case in this file builds its envelope with the same DER helpers
    // the parser was written against, so it can only prove self-consistency. This
    // envelope was produced by OpenSSL (`openssl cms -sign -binary -nodetach -md
    // sha256 -outform DER`) and validated independently by
    // Fixtures/make_cms_fixture.py, which checks the exact subset
    // `NativeProfileCMSEnvelope.parse` enforces. If the parser ever tightens or
    // drifts, this is the case that notices.

    static let fixturePayload = Data("com.example.vexsign.fixture-profile-payload".utf8)

    /// `openssl cms -sign …` output, base64. SHA-256 of the decoded bytes is
    /// `d2ecc474a54889b8896984fbf83ddcca836988e4e7810ffb6514acc756eee4db`; the generator re-checks that digest.
    static let fixtureCMSBase64 = """
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
myhbZsOZ2MR7BOmiTQ==
"""

    /// Bytes emitted by `openssl cms -sign -binary -nodetach -md sha256`, then
    /// checked by `Fixtures/make_cms_fixture.py` against the subset the parser
    /// accepts. Inlined as a literal rather than a bundle resource: this file is
    /// compiled twice (package tests and the isolated smoke graph), and a
    /// resource path that resolves in one layout and not the other is a build
    /// failure on the layout that CI actually runs.
    private func fixtureCMS() throws -> Data {
        try XCTUnwrap(Data(base64Encoded: Self.fixtureCMSBase64, options: .ignoreUnknownCharacters),
                      "fixture literal corrupted; regenerate with Fixtures/make_cms_fixture.py --generate")
    }

    func testOpenSSLBuiltEnvelopeParses() throws {
        let cms = try fixtureCMS()
        let parsed = try NativeProfileCMSEnvelope.parse(cms)
        XCTAssertEqual(parsed.payload, Self.fixturePayload)
        XCTAssertEqual(parsed.certificates.count, 1)
        XCTAssertEqual(parsed.signature.count, 256, "RSA 2048 PKCS#1 v1.5 signature")
        // OpenSSL adds signingTime; the parser must carry it in the signed set
        // without ever treating it as trust or expiry evidence.
        XCTAssertEqual(parsed.signedAttributes.first, 0x31, "signed attributes are re-tagged as a SET")
        XCTAssertFalse(parsed.signature.isEmpty)
    }

    func testOpenSSLBuiltEnvelopeStillNeedsAppleTrust() async throws {
        // A structurally valid, genuinely RSA-signed CMS from a self-signed
        // certificate must not become an accepted profile. Only the pin set and
        // the leaf/issuer CN checks can grant that, and they cannot pass here.
        let cms = try fixtureCMS()
        do {
            _ = try await NativeAppleProfileCMSVerifier().verifyAppleProvisioningCMS(cms, now: Date())
            XCTFail("Self-signed fixture must not pass Apple trust checks")
        } catch { XCTAssertEqual(error as? NativeProfileValidationError, .cmsRejected) }
    }

    func testOpenSSLBuiltEnvelopeTamperingIsRejected() throws {
        let cms = try fixtureCMS()

        // Flip one bit in the encapsulated payload: messageDigest no longer matches.
        var payloadTampered = cms
        let needle = Self.fixturePayload
        let range = try XCTUnwrap(payloadTampered.range(of: needle))
        payloadTampered[range.lowerBound] ^= 0x01
        XCTAssertThrowsError(try NativeProfileCMSEnvelope.parse(payloadTampered))

        // Flip one bit in the signature: structure still parses (the signature is
        // opaque to the envelope), so this documents the boundary precisely —
        // parse is shape-only, verifySignature is what rejects it.
        var signatureTampered = cms
        signatureTampered[signatureTampered.index(before: signatureTampered.endIndex)] ^= 0x01
        XCTAssertNoThrow(try NativeProfileCMSEnvelope.parse(signatureTampered))

        // Truncation and trailing bytes are structural failures.
        XCTAssertThrowsError(try NativeProfileCMSEnvelope.parse(Data(cms.dropLast())))
        XCTAssertThrowsError(try NativeProfileCMSEnvelope.parse(cms + Data([0])))
    }

    func testEphemeralRSASignatureAndTamperingPrimitive() throws {
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048, kSecAttrIsPermanent as String: false]
        let privateKey = try XCTUnwrap(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(privateKey))
        let message = Data("CMS signed attributes fixture".utf8)
        let signed = try XCTUnwrap(SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, nil)) as Data
        XCTAssertNoThrow(try NativeAppleProfileCMSVerifier.verifySignature(key: publicKey, message: message, signature: signed))
        XCTAssertThrowsError(try NativeAppleProfileCMSVerifier.verifySignature(key: publicKey, message: message + Data([0]), signature: signed))
        var tampered = signed; tampered[tampered.startIndex] ^= 1
        XCTAssertThrowsError(try NativeAppleProfileCMSVerifier.verifySignature(key: publicKey, message: message, signature: tampered))
    }
}
