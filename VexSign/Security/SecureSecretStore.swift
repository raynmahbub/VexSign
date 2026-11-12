import Foundation
import Security
import CryptoKit

enum SecureSecretStore {
    struct Failure: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)" }
    }
    static func read(_ account: String, service: String = "com.vexsign.secrets") throws -> Data? {
        var query = base(account, service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw Failure(status: status) }
        return data
    }
    static func write(_ data: Data, account: String, service: String = "com.vexsign.secrets") throws {
        let query = base(account, service)
        let attributes: [String: Any] = [kSecValueData as String: data,
                                        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
            if status == errSecDuplicateItem { status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary) }
        }
        guard status == errSecSuccess else { throw Failure(status: status) }
    }
    static func delete(_ account: String, service: String = "com.vexsign.secrets") throws {
        let status = SecItemDelete(base(account, service) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }
    /// Removes legacy plaintext only after a successful Keychain read/write.
    static func migrateDefaults(_ key: String, account: String) throws -> String {
        if let data = try read(account) {
            UserDefaults.standard.removeObject(forKey: key)
            return String(decoding: data, as: UTF8.self)
        }
        guard let value = UserDefaults.standard.string(forKey: key) else { return "" }
        try write(Data(value.utf8), account: account)
        UserDefaults.standard.removeObject(forKey: key)
        return value
    }
    private static func base(_ account: String, _ service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }
}

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
        catch { try? SecureSecretStore.delete(account) // try? ok: best-effort cleanup on write failure; throw error
        return url
    }
    func read(id: UUID, directory: URL) throws -> Data {
        guard let data = try SecureSecretStore.read("certificate.encryption.\(id.uuidString)") else { throw RepositoryError.invalid("Certificate key is unavailable.") }
        let ciphertext = try Data(contentsOf: directory.appendingPathComponent(id.uuidString + ".sealed"))
        return try AES.GCM.open(AES.GCM.SealedBox(combined: ciphertext), using: SymmetricKey(data: data), authenticating: Data(id.uuidString.utf8))
    }
    func delete(id: UUID, directory: URL) throws {
        try SecureSecretStore.delete("certificate.encryption.\(id.uuidString)")
        let url = directory.appendingPathComponent(id.uuidString + ".sealed")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
