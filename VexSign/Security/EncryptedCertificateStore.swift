import CryptoKit
import Foundation

/// New cloud/import staging material can be sealed without exposing private keys in
/// Documents. AES-GCM authenticates ciphertext; destroying its unique Keychain key
/// crypto-erases it. Flash storage cannot promise physical overwrite deletion.
actor EncryptedCertificateStore {
    // No process-wide singleton: instantiate where sealing is needed. (The former
    // `static let shared` had no callers; removing it shrinks the singleton freeze.)
    func store(_ p12: Data, id: UUID, directory: URL) throws -> URL {
        let account = "certificate.encryption.\(id.uuidString)"
        guard try SecureSecretStore.read(account) == nil else { throw RepositoryError.invalid("Certificate already exists.") }
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        let sealed = try AES.GCM.seal(p12, using: key, authenticating: Data(id.uuidString.utf8))
        guard let ciphertext = sealed.combined else { throw RepositoryError.invalid("Unable to encrypt certificate.") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(id.uuidString + ".sealed")
        try SecureSecretStore.write(keyData, account: account)
        do { try ciphertext.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
        catch {
            try? SecureSecretStore.delete(account) // try? ok: cleanup is best-effort and must not mask the file-write error
            throw error
        }
        return url
    }

    func read(id: UUID, directory: URL) throws -> Data {
        guard let data = try SecureSecretStore.read("certificate.encryption.\(id.uuidString)") else {
            throw RepositoryError.invalid("Certificate key is unavailable.")
        }
        let ciphertext = try Data(contentsOf: directory.appendingPathComponent(id.uuidString + ".sealed"))
        return try AES.GCM.open(
            AES.GCM.SealedBox(combined: ciphertext),
            using: SymmetricKey(data: data),
            authenticating: Data(id.uuidString.utf8)
        )
    }

    func delete(id: UUID, directory: URL) throws {
        try SecureSecretStore.delete("certificate.encryption.\(id.uuidString)")
        let url = directory.appendingPathComponent(id.uuidString + ".sealed")
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
