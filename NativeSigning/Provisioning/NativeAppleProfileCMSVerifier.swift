import Foundation
import Security
import CryptoKit

/// Public Security APIs only. Supported subset: definite-length DER CMS v1,
/// attached data, one issuer/serial signer, SHA-256 and RSA PKCS#1 v1.5 (2048–4096).
/// Unsupported BER/SHA-1/ECDSA/multi-signer/detached forms fail closed, not fallback.
/// Written but NOT native-compiled or cryptographically validated yet; not selected
/// by default and not a claim of compatibility with every Apple profile generation.
struct NativeAppleProfileCMSVerifier: NativeProfileCMSVerifying {
    private static let leafCN = "Apple iPhone OS Provisioning Profile Signing"
    private static let issuerCN = "Apple iPhone Certification Authority"
    // Apple public roots reviewed from immutable Apple Security source fixtures.
    // See apple-cms-policy-review.json. Embedded/self-signed roots are NOT anchors.
    private static let rootPins: Set<String> = [
        "b0b1730ecbc7ff4505142c49f1295e6eda6bcaed7e2c68c5be91b5a11001f024",
        "c2b9b042dd57830e7d117dac55ac8ae19407d38e41d88f3215bc3a890444a050",
        "63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179"
    ]
    func verifyAppleProvisioningCMS(_ cms: Data, now: Date) async throws -> Data {
        do {
            try Task.checkCancellation()
            guard now.timeIntervalSince1970.isFinite else { throw NativeProfileValidationError.cmsRejected }
            let envelope = try NativeProfileCMSEnvelope.parse(cms)
            var certificates: [SecCertificate] = []
            var matching: [Int] = []
            for der in envelope.certificates {
                guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else { throw NativeProfileValidationError.cmsRejected }
                let fields = try CertificateFields(der)
                if fields.issuer == envelope.signerIssuer && fields.serial == envelope.signerSerial { matching.append(certificates.count) }
                certificates.append(certificate)
            }
            guard matching.count == 1, let index = matching.first else { throw NativeProfileValidationError.cmsRejected }
            let signer = certificates[index]
            let fields = try CertificateFields(envelope.certificates[index])
            guard try Self.commonName(fields.subject) == Self.leafCN,
                  try Self.commonName(fields.issuer) == Self.issuerCN,
                  let key = SecCertificateCopyKey(signer) else { throw NativeProfileValidationError.cmsRejected }
            try Self.verifySignature(key: key, message: envelope.signedAttributes, signature: envelope.signature)
            try Task.checkCancellation()
            let ordered = [signer] + certificates.enumerated().filter { $0.offset != index }.map(\.element)
            var candidate: SecTrust?
            guard SecTrustCreateWithCertificates(ordered as CFArray, SecPolicyCreateBasicX509(), &candidate) == errSecSuccess,
                  let trust = candidate,
                  SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess,
                  SecTrustSetVerifyDate(trust, now as CFDate) == errSecSuccess,
                  SecTrustEvaluateWithError(trust, nil),
                  let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], chain.count == 3,
                  SecCertificateCopyData(chain[0]) as Data == envelope.certificates[index],
                  Self.rootPins.contains(NativeSigningIdentityOwner.hash(SecCertificateCopyData(chain[2]) as Data)) else {
                throw NativeProfileValidationError.cmsRejected
            }
            var trustResult = SecTrustResultType.invalid
            guard SecTrustGetTrustResult(trust, &trustResult) == errSecSuccess, trustResult == .unspecified else {
                // Explicit user trust overrides are not production Apple anchors.
                throw NativeProfileValidationError.cmsRejected
            }
            let intermediate = try CertificateFields(SecCertificateCopyData(chain[1]) as Data)
            guard try Self.commonName(intermediate.subject) == Self.issuerCN else { throw NativeProfileValidationError.cmsRejected }
            // Verify at supplied CURRENT time, not untrusted signed signingTime;
            // no network access, arbitrary custom anchors, trust bypass or logs.
            try Task.checkCancellation()
            return envelope.payload
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw NativeProfileValidationError.cmsRejected
        }
    }

    /// Signature primitive seam for deferred ephemeral-key fixtures; calling it
    /// alone never constructs authenticated CMS/profile output or grants trust.
    static func verifySignature(key: SecKey, message: Data, signature: Data) throws {
        guard let attrs = SecKeyCopyAttributes(key) as? [String: Any],
              attrs[kSecAttrKeyType as String] as? String == kSecAttrKeyTypeRSA as String,
              let bits = attrs[kSecAttrKeySizeInBits as String] as? Int,
              (2048...4096).contains(bits), bits % 8 == 0, signature.count == bits / 8,
              SecKeyIsAlgorithmSupported(key, .verify, .rsaSignatureMessagePKCS1v15SHA256),
              SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256,
                message as CFData, signature as CFData, nil) else { throw NativeProfileValidationError.cmsRejected }
    }

    private struct CertificateFields {
        let serial: Data
        let issuer: Data
        let subject: Data
        init(_ der: Data) throws {
            let cert = try NativeProfileDER.one(der, tag: 0x30).children(tag: 0x30, limit: 3)
            guard cert.count == 3 else { throw NativeProfileValidationError.cmsRejected }
            let tbs = try cert[0].children(tag: 0x30, limit: 16)
            guard !tbs.isEmpty else { throw NativeProfileValidationError.cmsRejected }
            let start = tbs[0].tag == 0xa0 ? 1 : 0
            guard tbs.count >= start + 6, tbs[start + 2].tag == 0x30, tbs[start + 4].tag == 0x30 else { throw NativeProfileValidationError.cmsRejected }
            try NativeProfileDER.positiveInteger(tbs[start])
            serial = tbs[start].encoded; issuer = tbs[start + 2].encoded; subject = tbs[start + 4].encoded
        }
    }
    private static func commonName(_ encodedName: Data) throws -> String {
        let rdns = try NativeProfileDER.one(encodedName, tag: 0x30).children(tag: 0x30, limit: 32)
        var names: [String] = []
        for rdn in rdns {
            for field in try rdn.children(tag: 0x31, limit: 8, sorted: true) {
                let pair = try field.children(tag: 0x30, limit: 2)
                guard pair.count == 2, pair[0].tag == 6 else { throw NativeProfileValidationError.cmsRejected }
                if pair[0].content == Data([0x55,0x04,0x03]) {
                    guard [UInt8(0x0c), 0x13, 0x16].contains(pair[1].tag), pair[1].content.count <= 256,
                          let text = String(data: pair[1].content, encoding: .utf8), text.utf8.allSatisfy({ $0 < 128 }) else { throw NativeProfileValidationError.cmsRejected }
                    names.append(text)
                }
            }
        }
        guard names.count == 1, let name = names.first else { throw NativeProfileValidationError.cmsRejected }
        return name
    }
}
