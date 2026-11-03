import Foundation
import Security
import SideSign

/// Apple Security RSA generation, in-memory only until the vault's atomic insert.
/// Constructs a minimal PKCS#10 CSR with CN=the operation's non-PII machine name.
/// Does not call the SDK's generate-and-submit certificate convenience method.
struct NativeSigningIdentityCrypto: NativeSigningIdentityGenerating {
    func generate(owner: NativeSigningIdentityOwner, id: UUID, now: Date) throws -> NativeSigningIdentityRecord {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: false]
        ]
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, nil),
              let secret = SecKeyCopyExternalRepresentation(key, nil) as Data? else {
            throw NativeSigningIdentityError.generationFailed
        }
        let publicKey = try Self.publicKeyDER(key)
        let csr = try Self.csr(key, publicKey: publicKey, machineName: "VexSign-" + id.uuidString)
        return NativeSigningIdentityRecord(schema: 1, ownerDigest: owner.digest, teamIdentifier: owner.teamIdentifier,
            id: id, createdAt: now, privateKeyDER: secret, publicKeyDER: publicKey, csrDER: csr,
            phase: .prepared, certificateDER: nil, certificateIdentifier: nil)
    }

    static func validateMaterial(_ record: NativeSigningIdentityRecord) throws {
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                                       kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
                                       kSecAttrKeySizeInBits as String: 2048]
        guard let key = SecKeyCreateWithData(record.privateKeyDER as CFData, attributes as CFDictionary, nil),
              let details = SecKeyCopyAttributes(key) as? [String: Any],
              details[kSecAttrKeySizeInBits as String] as? Int == 2048 else {
            throw NativeSigningIdentityError.invalidRecord
        }
        do {
            let publicKey = try publicKeyDER(key)
            // PKCS#1-v1.5 signing is deterministic: exact reconstruction proves
            // persisted CSR/key/public key/CN belong together, without accepting
            // arbitrary unparsed CSR fields or trusting a stored fingerprint.
            guard publicKey == record.publicKeyDER,
                  try csr(key, publicKey: publicKey, machineName: record.machineName) == record.csrDER else {
                throw NativeSigningIdentityError.invalidRecord
            }
            if let certificate = record.certificateDER {
                try validateCertificate(certificate, record: record, now: nil)
            }
        } catch { throw NativeSigningIdentityError.invalidRecord }
    }

    static func matchesPublicKey(_ data: Data, record: NativeSigningIdentityRecord) throws -> Bool {
        guard !data.isEmpty, data.count <= 64 * 1024, let certificate = X509Certificate(der: data) else {
            throw NativeSigningIdentityError.certificateRejected
        }
        return certificate.subjectPublicKeyInfoDER == record.publicKeyDER
    }

    /// Key/team/time matching only. Chain trust, certificate purpose/revocation,
    /// profile CMS and entitlement authorization remain separate acceptance gates.
    static func validateCertificate(_ data: Data, record: NativeSigningIdentityRecord, now: Date?) throws {
        guard !data.isEmpty, data.count <= 64 * 1024,
              let certificate = X509Certificate(der: data),
              certificate.subjectPublicKeyInfoDER == record.publicKeyDER,
              certificate.organizationalUnit == record.teamIdentifier,
              let notBefore = certificate.notBefore, let notAfter = certificate.notAfter,
              notBefore.timeIntervalSince1970.isFinite, notAfter.timeIntervalSince1970.isFinite,
              notBefore < notAfter else { throw NativeSigningIdentityError.certificateRejected }
        if let now {
            guard now.timeIntervalSince1970.isFinite, notBefore <= now, now < notAfter else {
                throw NativeSigningIdentityError.certificateRejected
            }
        }
    }

    private static func publicKeyDER(_ key: SecKey) throws -> Data {
        guard let publicKey = SecKeyCopyPublicKey(key),
              let rsa = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            throw NativeSigningIdentityError.generationFailed
        }
        let rsaEncryption = Data([0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00])
        return der(0x30, der(0x30, rsaEncryption) + der(0x03, Data([0]) + rsa))
    }

    private static func csr(_ key: SecKey, publicKey: Data, machineName: String) throws -> Data {
        let commonNameOID = Data([0x06, 0x03, 0x55, 0x04, 0x03])
        let subject = der(0x30, der(0x31, der(0x30, commonNameOID + der(0x0c, Data(machineName.utf8)))))
        let requestInfo = der(0x30, Data([0x02, 0x01, 0x00]) + subject + publicKey + Data([0xa0, 0x00]))
        guard SecKeyIsAlgorithmSupported(key, .sign, .rsaSignatureMessagePKCS1v15SHA256),
              let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, requestInfo as CFData, nil) as Data? else {
            throw NativeSigningIdentityError.generationFailed
        }
        let sha256WithRSA = Data([0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x0b, 0x05, 0x00])
        return der(0x30, requestInfo + der(0x30, sha256WithRSA) + der(0x03, Data([0]) + signature))
    }

    private static func der(_ tag: UInt8, _ value: Data) -> Data {
        var length = value.count
        var prefix = Data([tag])
        if length < 128 { prefix.append(UInt8(length)) }
        else {
            var bytes: [UInt8] = []
            while length > 0 { bytes.insert(UInt8(length & 255), at: 0); length >>= 8 }
            prefix.append(0x80 | UInt8(bytes.count))
            prefix.append(contentsOf: bytes)
        }
        return prefix + value
    }
}
