//
//  VaultPKCS12Opener.swift
//  VexSign
//
//  Opens a PKCS#12 entirely in memory. The identity is handed to the vault's
//  Keychain store; the imported bytes and the password are discarded at the
//  end of the call. Nothing here writes a temporary copy of the private key.
//

import Foundation
import Security

protocol VaultIdentityOpening: AnyObject {
    func open(data: Data, password: String) throws -> VaultOpenedIdentity
}

final class VaultPKCS12Opener: VaultIdentityOpening {
    func open(data: Data, password: String) throws -> VaultOpenedIdentity {
        let bytes = [UInt8](data)
        guard let envelope = DER.element(bytes, at: 0), envelope.tag == 0x30, envelope.end == bytes.count else {
            throw VaultError.malformedIdentity
        }
        var items: CFArray?
        let status = SecPKCS12Import(
            data as CFData,
            [kSecImportExportPassphrase as String: password] as CFDictionary,
            &items
        )
        guard status == errSecSuccess, let records = items as? [[String: Any]] else {
            throw Self.statusError(status)
        }
        let values = records.compactMap { $0[kSecImportItemIdentity as String] }
        guard values.count <= 1 else { throw VaultError.multipleIdentities }
        guard let value = values.first else { throw VaultError.missingPrivateKey }
        // Security owns this dictionary; the runtime type is checked before the cast.
        guard CFGetTypeID(value as CFTypeRef) == SecIdentityGetTypeID() else {
            throw VaultError.malformedIdentity
        }
        // swiftlint:disable:next force_cast
        let identity = value as! SecIdentity
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else {
            throw VaultError.malformedIdentity
        }
        let der = SecCertificateCopyData(certificate) as Data
        guard let signingIdentity = SigningIdentity(der) else { throw VaultError.malformedIdentity }
        let proof: SigningIdentityStore.Proof
        do {
            proof = try SigningIdentityStore.probe(identity)
        } catch {
            throw VaultError.unsupportedKey
        }
        guard proof.keyAvailability != .missing else { throw VaultError.missingPrivateKey }
        guard proof.keyAvailability == .accessible else { throw VaultError.keychainUnavailable }

        var keyType: String?
        var keySize: Int?
        var privateKey: SecKey?
        if SecIdentityCopyPrivateKey(identity, &privateKey) == errSecSuccess, let privateKey {
            if let attributes = SecKeyCopyAttributes(privateKey) as? NSDictionary {
                keySize = (attributes[kSecAttrKeySizeInBits as String] as? NSNumber)?.intValue
                if let type = attributes[kSecAttrKeyType as String] as? String {
                    keyType = type == kSecAttrKeyTypeRSA as String ? "RSA"
                        : type == kSecAttrKeyTypeECSECPrimeRandom as String ? "EC" : type
                }
            }
        }
        return VaultOpenedIdentity(
            identity: identity,
            metadata: VaultIdentityMetadata(
                fingerprint: signingIdentity.fingerprint,
                commonName: signingIdentity.commonName,
                issuerCommonName: signingIdentity.issuerCommonName,
                teamIdentifier: signingIdentity.teamIdentifier,
                serialNumber: signingIdentity.serial,
                notBefore: signingIdentity.notBefore,
                notAfter: signingIdentity.notAfter,
                keyAlgorithm: keyType,
                keySizeBits: keySize
            )
        )
    }

    private static func statusError(_ status: OSStatus) -> VaultError {
        switch status {
        // -25264 is errSecPkcs12VerifyFailure (MAC verification failed), which is
        // not exposed as a public Swift constant on every SDK.
        case errSecAuthFailed, -25264: return .wrongPassword
        case errSecDecode, errSecParam: return .malformedIdentity
        case errSecItemNotFound: return .missingPrivateKey
        default: return .keychainUnavailable
        }
    }
}
