import Foundation
import CoreData
import Security
import Zsign

/// A snapshot of the existing certificate store, not a second credential store.
/// Only locations and Keychain access are resolved on the owning actor. Bounded
/// parsing and the certificate/private-key challenge run off the main actor.
enum SigningIdentityStore {
    struct Input: Sendable {
        let reference: String
        let name: String
        let p12URL: URL?
        let profileURLs: [URL]
        let password: String?
        let revoked: Bool
        let notice: String?
    }

    @MainActor
    static func snapshot(storage: Storage = .shared,
        passwordReader: (CertificatePair) throws -> String = { try $0.requireSigningPassword() }) throws -> [Input] {
        let request = CertificatePair.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)]
        request.fetchLimit = 513
        let rows = try storage.context.fetch(request)
        guard rows.count <= 512 else { throw InspectionFailure.inventoryLimit }
        return rows.map { row in
            let name = row.nickname ?? "Imported identity"
            var p12: URL?
            var profiles: [URL] = []
            var notice: String?
            let hasValidUUID = row.uuid.flatMap { UUID(uuidString: $0) } != nil
            do {
                guard hasValidUUID else { throw InspectionFailure.certificateMissing }
                guard let root = storage.getUuidDirectory(for: row) else { throw InspectionFailure.certificateMissing }
                let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else { throw InspectionFailure.certificateMissing }
                let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                guard files.count <= 1024 else { throw InspectionFailure.inventoryLimit }
                let identities = files.filter { $0.pathExtension.lowercased() == "p12" }
                guard identities.count <= 1 else { throw InspectionFailure.multipleIdentities }
                p12 = identities.first
                profiles = files.filter { $0.pathExtension.lowercased() == "mobileprovision" }
                let additional = root.appendingPathComponent(AdditionalProfiles.folderName, isDirectory: true)
                if FileManager.default.fileExists(atPath: additional.path) {
                    let values = try additional.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    guard values.isDirectory == true, values.isSymbolicLink != true else { throw InspectionFailure.certificateMissing }
                    profiles += try FileManager.default.contentsOfDirectory(at: additional, includingPropertiesForKeys: nil)
                        .filter { $0.pathExtension.lowercased() == "mobileprovision" }
                }
                guard profiles.count <= 512 else { throw InspectionFailure.inventoryLimit }
                if p12 == nil { notice = InspectionFailure.certificateMissing.localizedDescription }
            } catch {
                // One corrupt identity must not hide other valid identities, but
                // its failure is visible. No inventory is silently truncated.
                p12 = nil; profiles = []
                notice = error.localizedDescription
            }
            let rejected = row.revoked || SigningIdentityPolicy.rejection(
                storedSnapshot: row.uuid.flatMap { CertificateRevocationSnapshot.stored(forCertificateUUID: $0) }) != nil
            var password: String?
            if hasValidUUID {
                do { password = try passwordReader(row) }
                catch {
                    // An unavailable Keychain is not an empty password. Expose
                    // fixed actionable evidence, never secret/error payloads.
                    notice = [notice, InspectionFailure.inaccessible.localizedDescription]
                        .compactMap { $0 }.joined(separator: "\n")
                }
            }
            return Input(reference: row.objectID.uriRepresentation().absoluteString, name: name, p12URL: p12,
                profileURLs: profiles.sorted { $0.path < $1.path }, password: password,
                revoked: rejected, notice: notice)
        }
    }

    static func leaseKey(reference: String) -> String { "signing-identity:" + reference }

    struct LeasedInventory: Sendable {
        let inputs: [Input]
        let leases: [AppOperationRegistry.Lease]
    }

    /// MainActor deletion owners check these same keys before moving any files.
    /// Holding all imported rows also protects cross-row additional profiles.
    @MainActor
    static func leasedSnapshot(storage: Storage = .shared,
        passwordReader: (CertificatePair) throws -> String = { try $0.requireSigningPassword() }) throws -> LeasedInventory {
        let inputs = try snapshot(storage: storage, passwordReader: passwordReader)
        let leases = try inputs.map { try AppOperationRegistry.shared.acquire(leaseKey(reference: $0.reference)) }
        return LeasedInventory(inputs: inputs, leases: leases)
    }

    @MainActor
    static func requireCurrent(_ references: Set<String>, matching inputs: [Input]? = nil, storage: Storage = .shared,
        passwordReader: (CertificatePair) throws -> String = { try $0.requireSigningPassword() }) throws {
        for reference in references {
            let row = try storage.managedCertificate(id: reference)
            guard !row.isDeleted, !row.revoked, row.uuid.flatMap({ UUID(uuidString: $0) }) != nil,
                  SigningIdentityPolicy.rejection(storedSnapshot: row.uuid.flatMap {
                      CertificateRevocationSnapshot.stored(forCertificateUUID: $0)
                  }) == nil else { throw InspectionFailure.inaccessible }
            let currentPassword: String
            do { currentPassword = try passwordReader(row) }
            catch { throw InspectionFailure.inaccessible }
            if let inputs {
                guard let original = inputs.first(where: { $0.reference == reference }),
                      let password = original.password, password == currentPassword else {
                    throw InspectionFailure.inaccessible
                }
            }
        }
    }

    struct Proof {
        let identity: SigningIdentity
        let keyAvailability: SigningIdentityCandidate.KeyAvailability
        let nativeSigningSupported: Bool
    }

    /// Never substitutes a profile certificate for the actual PKCS#12 leaf.
    /// Security imports the identity without exporting a key; a random challenge
    /// proves that its private key matches the public key in that certificate.
    static func inspect(_ data: Data, password: String?) throws -> Proof {
        guard data.count <= CertificateInputReader.maximumBytes else { throw InspectionFailure.inventoryLimit }
        guard let password else { throw InspectionFailure.inaccessible }
        let encoded = [UInt8](data)
        guard let envelope = DER.element(encoded, at: 0), envelope.tag == 0x30, envelope.end == encoded.count else {
            throw InspectionFailure.malformedPKCS12
        }
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData,
            [kSecImportExportPassphrase as String: password] as CFDictionary, &items)
        guard status == errSecSuccess, let records = items as? [[String: Any]] else {
            if status == errSecDecode { throw InspectionFailure.malformedPKCS12 }
            throw InspectionFailure.inaccessible
        }
        let values = records.compactMap { $0[kSecImportItemIdentity as String] }
        guard values.count <= 1 else { throw InspectionFailure.multipleIdentities }
        guard let value = values.first else { throw InspectionFailure.privateKeyMissing }
        guard CFGetTypeID(value as CFTypeRef) == SecIdentityGetTypeID() else { throw InspectionFailure.malformedPKCS12 }
        // Security owns the dictionary schema; the runtime type ID was checked.
        // swiftlint:disable:next force_cast
        let reference = value as! SecIdentity
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(reference, &certificate) == errSecSuccess, let certificate,
              let identity = SigningIdentity(SecCertificateCopyData(certificate) as Data) else {
            throw InspectionFailure.certificateMissing
        }
        return try prove(reference, certificate: certificate, identity: identity)
    }

    /// Proves that the private key behind an already-resolved `SecIdentity` really
    /// matches its leaf certificate. Used by the certificate vault, whose identities
    /// live in the Keychain rather than in a staged PKCS#12 file. No key bytes are
    /// exported, and no password is involved.
    static func probe(_ reference: SecIdentity) throws -> Proof {
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(reference, &certificate) == errSecSuccess, let certificate,
              let identity = SigningIdentity(SecCertificateCopyData(certificate) as Data) else {
            throw InspectionFailure.certificateMissing
        }
        return try prove(reference, certificate: certificate, identity: identity)
    }

    private static func prove(
        _ reference: SecIdentity,
        certificate: SecCertificate,
        identity: SigningIdentity
    ) throws -> Proof {
        let nativeSigningSupported = VexNativeSupportsSigningCertificate(SecCertificateCopyData(certificate) as Data)
        var privateKey: SecKey?
        let keyStatus = SecIdentityCopyPrivateKey(reference, &privateKey)
        guard keyStatus == errSecSuccess, let privateKey else {
            return Proof(identity: identity, keyAvailability: keyStatus == errSecItemNotFound ? .missing : .inaccessible,
                nativeSigningSupported: nativeSigningSupported)
        }
        guard let publicKey = SecCertificateCopyKey(certificate) else { throw InspectionFailure.certificateMissing }
        let algorithm: SecKeyAlgorithm
        if SecKeyIsAlgorithmSupported(privateKey, .sign, .rsaSignatureMessagePKCS1v15SHA256) {
            algorithm = .rsaSignatureMessagePKCS1v15SHA256
        } else if SecKeyIsAlgorithmSupported(privateKey, .sign, .ecdsaSignatureMessageX962SHA256) {
            algorithm = .ecdsaSignatureMessageX962SHA256
        } else { throw InspectionFailure.unsupportedKey }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw InspectionFailure.inaccessible
        }
        let challenge = Data(bytes)
        guard let signature = SecKeyCreateSignature(privateKey, algorithm, challenge as CFData, nil),
              SecKeyVerifySignature(publicKey, algorithm, challenge as CFData, signature, nil) else {
            return Proof(identity: identity, keyAvailability: .inaccessible, nativeSigningSupported: nativeSigningSupported)
        }
        return Proof(identity: identity, keyAvailability: .accessible, nativeSigningSupported: nativeSigningSupported)
    }

    enum InspectionFailure: LocalizedError {
        case certificateMissing, privateKeyMissing, multipleIdentities, inaccessible, malformedPKCS12, unsupportedKey, inventoryLimit
        var errorDescription: String? {
            switch self {
            case .certificateMissing: return "The signing certificate or .p12 file is missing. Import the complete identity."
            case .privateKeyMissing: return "A certificate without its matching private key is not a signing identity. Import a complete .p12."
            case .multipleIdentities: return "More than one identity was found. Import each certificate/private-key pair separately so selection is unambiguous."
            case .inaccessible: return "The signing identity could not be opened. Unlock the device and verify the saved .p12 password in Certificates."
            case .malformedPKCS12: return "The .p12 is malformed or unreadable; it has not been accepted as an identity."
            case .unsupportedKey: return "This private-key algorithm is not supported by the identity proof. Import a supported Apple-issued RSA or EC signing identity."
            case .inventoryLimit: return "The signing inventory exceeds the bounded inspection limit. Remove duplicate files and retry; no partial inventory has been selected."
            }
        }
    }
}
