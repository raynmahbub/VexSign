import Foundation
import Security

/// Cryptographic consistency ONLY, not chain trust/revocation, archive integrity,
/// execution approval or device installation authority. No public constructor.
struct NativeDetachedCodeSignatureEvidence: Sendable {
    let codeDirectorySHA256: String
    let certificateSHA256: String
    fileprivate init(directory: Data, certificate: Data) {
        codeDirectorySHA256 = NativeSigningIdentityOwner.hash(directory)
        certificateSHA256 = NativeSigningIdentityOwner.hash(certificate)
    }
}

struct NativeDetachedCodeSignatureVerifier {
    static func verify(cms: Data, codeDirectory: Data, expectedCertificate: Data) throws -> NativeDetachedCodeSignatureEvidence {
        do {
            try Task.checkCancellation()
            guard !expectedCertificate.isEmpty, expectedCertificate.count <= 64 * 1024 else { throw NativeSignedOutputError.invalidSignature }
            let envelope = try NativeProfileCMSEnvelope.parseDetachedCodeSignature(cms, codeDirectory: codeDirectory)
            var matches: [Data] = []
            for der in envelope.certificates {
                let certificate = try NativeProfileDER.one(der, tag: 0x30).children(tag: 0x30, limit: 3)
                guard certificate.count == 3 else { throw NativeSignedOutputError.invalidSignature }
                let tbs = try certificate[0].children(tag: 0x30, limit: 16)
                let start = tbs.first?.tag == 0xa0 ? 1 : 0
                guard tbs.count >= start + 6, tbs[start + 2].tag == 0x30 else { throw NativeSignedOutputError.invalidSignature }
                try NativeProfileDER.positiveInteger(tbs[start])
                if tbs[start].encoded == envelope.signerSerial && tbs[start + 2].encoded == envelope.signerIssuer { matches.append(der) }
            }
            guard matches == [expectedCertificate],
                  let leaf = SecCertificateCreateWithData(nil, expectedCertificate as CFData),
                  let key = SecCertificateCopyKey(leaf) else { throw NativeSignedOutputError.invalidSignature }
            // RSA 2048–4096, exact signature length, SHA256/PKCS1v1.5. Primitive
            // shared with profile role; certificate purpose/trust is NOT shared.
            try NativeAppleProfileCMSVerifier.verifySignature(key: key, message: envelope.signedAttributes, signature: envelope.signature)
            try Task.checkCancellation()
            return NativeDetachedCodeSignatureEvidence(directory: codeDirectory, certificate: expectedCertificate)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw NativeSignedOutputError.invalidSignature
        }
    }
}
