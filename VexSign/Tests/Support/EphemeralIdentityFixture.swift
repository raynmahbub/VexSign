import CommonCrypto
import CryptoKit
import Foundation
import Security
@testable import VexSign

enum EphemeralIdentityFixture {
    struct GeneratedIdentity {
        let privateKey: SecKey
        let publicKey: SecKey
        let certificateDER: Data
        let commonName: String
        let teamIdentifier: String
        let serialNumber: Data
    }

    enum FixtureError: Error {
        case keyGenerationFailed
        case keyExportFailed
        case signingFailed
        case cryptoFailed(Int32)
        case invalidCMS
    }

    static func generateIdentity(
        commonName: String = "VexSign Ephemeral Dev",
        teamIdentifier: String = SigningRegressionFixture.team,
        notBefore: Date = Date().addingTimeInterval(-3600),
        notAfter: Date = Date().addingTimeInterval(86_400 * 30),
        issuer: GeneratedIdentity? = nil
    ) throws -> GeneratedIdentity {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
              let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw FixtureError.keyGenerationFailed
        }
        guard let publicKeyDER = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw FixtureError.keyExportFailed
        }

        let serial = randomBytes(count: 8, ensurePositive: true)
        let subjectDN = encodeDistinguishedName(commonName: commonName, organizationalUnit: teamIdentifier)
        let issuerDN = issuer.map {
            encodeDistinguishedName(commonName: $0.commonName, organizationalUnit: $0.teamIdentifier)
        } ?? subjectDN

        let rsaAlgID = derSequence(derOID("1.2.840.113549.1.1.1") + derNull())
        let sha256WithRSAAlgID = derSequence(derOID("1.2.840.113549.1.1.11") + derNull())
        let spki = derSequence(rsaAlgID + derBitString(publicKeyDER))
        let validity = derSequence(derUTCTime(notBefore) + derUTCTime(notAfter))

        let tbsCertificate = derSequence(
            derContextExplicit(0, derInteger(2))
                + derInteger(bytes: serial)
                + sha256WithRSAAlgID
                + issuerDN
                + validity
                + subjectDN
                + spki
        )

        let signingKey = issuer?.privateKey ?? privateKey
        guard let signature = SecKeyCreateSignature(
            signingKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            tbsCertificate as CFData,
            &error
        ) as Data? else {
            throw FixtureError.signingFailed
        }

        let certificateDER = derSequence(
            tbsCertificate + sha256WithRSAAlgID + derBitString(signature)
        )
        return GeneratedIdentity(
            privateKey: privateKey,
            publicKey: publicKey,
            certificateDER: certificateDER,
            commonName: commonName,
            teamIdentifier: teamIdentifier,
            serialNumber: serial
        )
    }

    /// Builds a standards-compliant RFC 7292 PKCS#12 archive (PBES2 PBKDF2-HMAC-SHA256 +
    /// AES-256-CBC + HMAC-SHA256 MacData) accepted by Apple's `SecPKCS12Import`.
    static func buildPKCS12(
        identities: [GeneratedIdentity],
        password: String,
        includePrivateKeys: Bool = true
    ) throws -> Data {
        let iterations = 2048
        var keyBags = Data()
        var certBags = Data()

        for identity in identities {
            let localKeyID = Data(Insecure.SHA1.hash(data: identity.certificateDER))
            let attrs = derSet(
                derSequence(
                    derOID("1.2.840.113549.1.9.21") + derSet(derOctetString(localKeyID))
                ) + derSequence(
                    derOID("1.2.840.113549.1.9.20") + derSet(derBMPString(identity.commonName))
                )
            )

            if includePrivateKeys {
                var error: Unmanaged<CFError>?
                guard let rsaPrivateKeyDER = SecKeyCopyExternalRepresentation(
                    identity.privateKey,
                    &error
                ) as Data? else {
                    throw FixtureError.keyExportFailed
                }
                let pkcs8 = derSequence(
                    derInteger(0)
                        + derSequence(derOID("1.2.840.113549.1.1.1") + derNull())
                        + derOctetString(rsaPrivateKeyDER)
                )
                let salt = randomBytes(count: 16)
                let iv = randomBytes(count: 16)
                let derivedKey = try pbkdf2SHA256(password: password, salt: salt, iterations: iterations, keyLength: 32)
                let encryptedPKCS8 = try aes256CBCEncrypt(plaintext: pkcs8, key: derivedKey, iv: iv)

                let prf = derSequence(derOID("1.2.840.113549.2.9") + derNull())
                let pbkdf2Params = derSequence(derOctetString(salt) + derInteger(iterations) + prf)
                let kdfAlg = derSequence(derOID("1.2.840.113549.1.5.12") + pbkdf2Params)
                let encAlg = derSequence(derOID("2.16.840.1.101.3.4.1.42") + derOctetString(iv))
                let pbes2Alg = derSequence(derOID("1.2.840.113549.1.5.13") + derSequence(kdfAlg + encAlg))

                let epki = derSequence(pbes2Alg + derOctetString(encryptedPKCS8))
                let keyBag = derSequence(
                    derOID("1.2.840.113549.1.12.10.1.2")
                        + derContextExplicit(0, epki)
                        + attrs
                )
                keyBags.append(keyBag)
            }

            let certValue = derSequence(
                derOID("1.2.840.113549.1.9.22.1") + derContextExplicit(0, derOctetString(identity.certificateDER))
            )
            let certBag = derSequence(
                derOID("1.2.840.113549.1.12.10.1.3")
                    + derContextExplicit(0, certValue)
                    + attrs
            )
            certBags.append(certBag)
        }

        var safeContentsList = Data()
        if !keyBags.isEmpty {
            let keySafe = derSequence(keyBags)
            safeContentsList.append(
                derSequence(derOID("1.2.840.113549.1.7.1") + derContextExplicit(0, derOctetString(keySafe)))
            )
        }
        let certSafe = derSequence(certBags)
        safeContentsList.append(
            derSequence(derOID("1.2.840.113549.1.7.1") + derContextExplicit(0, derOctetString(certSafe)))
        )

        let authSafe = derSequence(safeContentsList)
        let authSafeContentInfo = derSequence(
            derOID("1.2.840.113549.1.7.1") + derContextExplicit(0, derOctetString(authSafe))
        )

        let macSalt = randomBytes(count: 16)
        let macKey = pkcs12KDFSHA256(
            password: password,
            salt: macSalt,
            iterations: iterations,
            purposeID: 3,
            length: 32
        )
        let macDigest = Data(HMAC<SHA256>.authenticationCode(for: authSafe, using: SymmetricKey(data: macKey)))
        let digestInfo = derSequence(
            derSequence(derOID("2.16.840.1.101.3.4.2.1") + derNull()) + derOctetString(macDigest)
        )
        let macData = derSequence(digestInfo + derOctetString(macSalt) + derInteger(iterations))

        return derSequence(derInteger(3) + authSafeContentInfo + macData)
    }

    /// Wraps an XML provisioning profile plist in a real RFC 5652 CMS SignedData envelope
    /// signed by `signer` with RSA-SHA256.
    static func buildSignedProvisioningProfileCMS(
        profile: Certificate,
        signer: GeneratedIdentity
    ) throws -> Data {
        let plistData = try SigningRegressionFixture.unsignedProfileData(profile)
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            signer.privateKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            plistData as CFData,
            &error
        ) as Data? else {
            throw FixtureError.signingFailed
        }

        let sha256Alg = derSequence(derOID("2.16.840.1.101.3.4.2.1") + derNull())
        let rsaAlg = derSequence(derOID("1.2.840.113549.1.1.1") + derNull())
        let encapContent = derSequence(
            derOID("1.2.840.113549.1.7.1") + derContextExplicit(0, derOctetString(plistData))
        )
        let certificates = derContextImplicit(0, signer.certificateDER)
        let issuerDN = encodeDistinguishedName(
            commonName: signer.commonName,
            organizationalUnit: signer.teamIdentifier
        )
        let sid = derSequence(issuerDN + derInteger(bytes: signer.serialNumber))
        let signerInfo = derSequence(
            derInteger(1) + sid + sha256Alg + rsaAlg + derOctetString(signature)
        )
        let signedData = derSequence(
            derInteger(1)
                + derSet(sha256Alg)
                + encapContent
                + certificates
                + derSet(signerInfo)
        )
        return derSequence(derOID("1.2.840.113549.1.7.2") + derContextExplicit(0, signedData))
    }

    /// Test-only CMS verifier that cryptographically verifies the RSA-SHA256 signature in
    /// a test-generated CMS envelope against an explicit ephemeral `trustedSigner`, then
    /// runs production `ProvisioningProfileParser.validateMetadata`.
    static func parseAndVerifyTestCMS(
        _ cmsData: Data,
        trustedSigner: GeneratedIdentity,
        now: Date = Date(),
        allowingExpiredForDisplay: Bool = false
    ) throws -> Certificate {
        let bytes = [UInt8](cmsData)
        guard let outer = DER.element(bytes, at: 0), outer.tag == 0x30, outer.end == bytes.count,
              let contentType = DER.element(bytes, at: outer.content, limit: outer.end),
              let contentWrapper = DER.element(bytes, at: contentType.end, limit: outer.end),
              contentWrapper.tag == 0xa0,
              let signedData = DER.element(bytes, at: contentWrapper.content, limit: contentWrapper.end),
              signedData.tag == 0x30 else {
            throw FixtureError.invalidCMS
        }

        var cursor = signedData.content
        var children: [DER.Element] = []
        while cursor < signedData.end {
            guard let child = DER.element(bytes, at: cursor, limit: signedData.end) else {
                throw FixtureError.invalidCMS
            }
            children.append(child)
            cursor = child.end
        }
        guard children.count >= 4 else { throw FixtureError.invalidCMS }

        let encap = children[2]
        guard let encapOID = DER.element(bytes, at: encap.content, limit: encap.end),
              let encapExplicit = DER.element(bytes, at: encapOID.end, limit: encap.end),
              encapExplicit.tag == 0xa0,
              let payloadOctets = DER.element(bytes, at: encapExplicit.content, limit: encapExplicit.end),
              payloadOctets.tag == 0x04 else {
            throw FixtureError.invalidCMS
        }
        let plistData = Data(bytes[payloadOctets.content..<payloadOctets.end])

        guard let signerInfosSet = children.last, signerInfosSet.tag == 0x31,
              let signerInfo = DER.element(bytes, at: signerInfosSet.content, limit: signerInfosSet.end),
              signerInfo.tag == 0x30 else {
            throw FixtureError.invalidCMS
        }
        var siCursor = signerInfo.content
        var siFields: [DER.Element] = []
        while siCursor < signerInfo.end {
            guard let field = DER.element(bytes, at: siCursor, limit: signerInfo.end) else {
                throw FixtureError.invalidCMS
            }
            siFields.append(field)
            siCursor = field.end
        }
        guard let sigField = siFields.last, sigField.tag == 0x04 else {
            throw FixtureError.invalidCMS
        }
        let signature = Data(bytes[sigField.content..<sigField.end])

        var verifyError: Unmanaged<CFError>?
        guard SecKeyVerifySignature(
            trustedSigner.publicKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            plistData as CFData,
            signature as CFData,
            &verifyError
        ) else {
            throw ProvisioningProfileParser.Failure.untrustedCMS
        }

        let decoded = try PropertyListDecoder().decode(Certificate.self, from: plistData)
        try ProvisioningProfileParser.validateMetadata(
            decoded,
            now: now,
            allowingExpiredForDisplay: allowingExpiredForDisplay
        )
        return decoded
    }

    // MARK: - Crypto Primitives

    private static func randomBytes(count: Int, ensurePositive: Bool = false) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        if ensurePositive, !bytes.isEmpty {
            bytes[0] = (bytes[0] & 0x7f) | 0x01
        }
        return Data(bytes)
    }

    private static func pbkdf2SHA256(
        password: String,
        salt: Data,
        iterations: Int,
        keyLength: Int
    ) throws -> Data {
        let passwordData = Data(password.utf8)
        var derived = [UInt8](repeating: 0, count: keyLength)
        let status: Int32 = passwordData.withUnsafeBytes { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                let pwPtr = passwordBytes.bindMemory(to: Int8.self).baseAddress
                let saltPtr = saltBytes.bindMemory(to: UInt8.self).baseAddress
                return CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pwPtr,
                    passwordData.count,
                    saltPtr,
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(iterations),
                    &derived,
                    keyLength
                )
            }
        }
        guard status == kCCSuccess else { throw FixtureError.cryptoFailed(status) }
        return Data(derived)
    }

    private static func aes256CBCEncrypt(plaintext: Data, key: Data, iv: Data) throws -> Data {
        let outCapacity = plaintext.count + kCCBlockSizeAES128
        var output = [UInt8](repeating: 0, count: outCapacity)
        var outLength = 0
        let status: CCCryptorStatus = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                plaintext.withUnsafeBytes { plainBytes in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyBytes.baseAddress,
                        key.count,
                        ivBytes.baseAddress,
                        plainBytes.baseAddress,
                        plaintext.count,
                        &output,
                        outCapacity,
                        &outLength
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw FixtureError.cryptoFailed(status) }
        return Data(output.prefix(outLength))
    }

    /// RFC 7292 Appendix B.2 PKCS#12 KDF with SHA-256 (u = 32, v = 64).
    private static func pkcs12KDFSHA256(
        password: String,
        salt: Data,
        iterations: Int,
        purposeID: UInt8,
        length: Int
    ) -> Data {
        let digestLen = 32
        let blockLen = 64
        let diversifier = [UInt8](repeating: purposeID, count: blockLen)

        var pwBytes: [UInt8] = []
        for unit in password.utf16 {
            pwBytes.append(UInt8(unit >> 8))
            pwBytes.append(UInt8(unit & 0xff))
        }
        pwBytes.append(0)
        pwBytes.append(0)

        func repeatToBlockMultiple(_ input: [UInt8]) -> [UInt8] {
            guard !input.isEmpty else { return [] }
            let target = blockLen * ((input.count + blockLen - 1) / blockLen)
            var out = [UInt8]()
            out.reserveCapacity(target)
            while out.count < target {
                out.append(contentsOf: input)
            }
            return Array(out.prefix(target))
        }

        var combined = repeatToBlockMultiple([UInt8](salt)) + repeatToBlockMultiple(pwBytes)
        let chunks = (length + digestLen - 1) / digestLen
        var derived = [UInt8]()
        derived.reserveCapacity(chunks * digestLen)

        for _ in 0..<chunks {
            var block = [UInt8](SHA256.hash(data: Data(diversifier + combined)))
            for _ in 1..<iterations {
                block = [UInt8](SHA256.hash(data: Data(block)))
            }
            derived.append(contentsOf: block)

            let bVec = repeatToBlockMultiple(block)
            var offset = 0
            while offset < combined.count {
                var carry: UInt16 = 1
                for idx in stride(from: blockLen - 1, through: 0, by: -1) {
                    let sum = UInt16(combined[offset + idx]) + UInt16(bVec[idx]) + carry
                    combined[offset + idx] = UInt8(sum & 0xff)
                    carry = sum >> 8
                }
                offset += blockLen
            }
        }
        return Data(derived.prefix(length))
    }

    // MARK: - Minimal ASN.1 DER Encoder

    private static func derLength(_ count: Int) -> Data {
        if count < 0x80 {
            return Data([UInt8(count)])
        }
        var remaining = count
        var bytes: [UInt8] = []
        while remaining > 0 {
            bytes.insert(UInt8(remaining & 0xff), at: 0)
            remaining >>= 8
        }
        return Data([UInt8(0x80 | bytes.count)] + bytes)
    }

    private static func derTLV(_ tag: UInt8, _ body: Data) -> Data {
        Data([tag]) + derLength(body.count) + body
    }

    private static func derSequence(_ body: Data) -> Data { derTLV(0x30, body) }
    private static func derSet(_ body: Data) -> Data { derTLV(0x31, body) }
    private static func derOctetString(_ body: Data) -> Data { derTLV(0x04, body) }
    private static func derNull() -> Data { Data([0x05, 0x00]) }
    private static func derBitString(_ body: Data) -> Data { derTLV(0x03, Data([0x00]) + body) }
    private static func derUTF8String(_ text: String) -> Data { derTLV(0x0c, Data(text.utf8)) }

    private static func derBMPString(_ text: String) -> Data {
        var bytes: [UInt8] = []
        for unit in text.utf16 {
            bytes.append(UInt8(unit >> 8))
            bytes.append(UInt8(unit & 0xff))
        }
        return derTLV(0x1e, Data(bytes))
    }

    private static func derContextExplicit(_ index: UInt8, _ body: Data) -> Data {
        derTLV(0xa0 | index, body)
    }

    private static func derContextImplicit(_ index: UInt8, _ body: Data) -> Data {
        derTLV(0xa0 | index, body)
    }

    private static func derInteger(_ value: Int) -> Data {
        if value == 0 { return derTLV(0x02, Data([0x00])) }
        var remaining = value
        var bytes: [UInt8] = []
        while remaining > 0 {
            bytes.insert(UInt8(remaining & 0xff), at: 0)
            remaining >>= 8
        }
        if let first = bytes.first, first & 0x80 != 0 {
            bytes.insert(0x00, at: 0)
        }
        return derTLV(0x02, Data(bytes))
    }

    private static func derInteger(bytes: Data) -> Data {
        var raw = [UInt8](bytes)
        if let first = raw.first, first & 0x80 != 0 {
            raw.insert(0x00, at: 0)
        }
        return derTLV(0x02, Data(raw))
    }

    private static func derOID(_ dotted: String) -> Data {
        let parts = dotted.split(separator: ".").compactMap { UInt64($0) }
        guard parts.count >= 2 else { return derTLV(0x06, Data()) }
        var encoded: [UInt8] = [UInt8(40 * parts[0] + parts[1])]
        for component in parts.dropFirst(2) {
            if component == 0 {
                encoded.append(0)
            } else {
                var value = component
                var chunks: [UInt8] = []
                while value > 0 {
                    chunks.insert(UInt8(value & 0x7f), at: 0)
                    value >>= 7
                }
                for (index, byte) in chunks.enumerated() {
                    encoded.append(index < chunks.count - 1 ? (byte | 0x80) : byte)
                }
            }
        }
        return derTLV(0x06, Data(encoded))
    }

    private static func derUTCTime(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        return derTLV(0x17, Data(formatter.string(from: date).utf8))
    }

    private static func encodeDistinguishedName(commonName: String, organizationalUnit: String) -> Data {
        let cnAttr = derSet(derSequence(derOID("2.5.4.3") + derUTF8String(commonName)))
        let ouAttr = derSet(derSequence(derOID("2.5.4.11") + derUTF8String(organizationalUnit)))
        return derSequence(cnAttr + ouAttr)
    }
}
