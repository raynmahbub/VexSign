import Foundation
import Security

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

    /// Atomically creates a trust record only when absent. Unlike `write`, it can
    /// never replace a previously paired certificate during concurrent enrollment.
    static func writeIfAbsent(_ data: Data, account: String, service: String = "com.vexsign.secrets") throws {
        var request = base(account, service)
        request[kSecValueData as String] = data
        request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(request as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure(status: status) }
    }
    static func delete(_ account: String, service: String = "com.vexsign.secrets") throws {
        let status = SecItemDelete(base(account, service) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }
    /// Removes legacy plaintext only after a successful Keychain read/write.
    static func migrateDefaults(_ key: String, account: String) throws -> String {
        try migrateDefaults(
            key,
            account: account,
            defaults: .standard,
            read: { try SecureSecretStore.read($0) },
            write: { data, account in try SecureSecretStore.write(data, account: account) }
        )
    }

    /// Injectable migration seam. Tests can verify failure ordering without using
    /// a device Keychain; production callers use the overload above.
    static func migrateDefaults(
        _ key: String,
        account: String,
        defaults: UserDefaults,
        read: (String) throws -> Data?,
        write: (Data, String) throws -> Void
    ) throws -> String {
        if let data = try read(account) {
            defaults.removeObject(forKey: key)
            return String(decoding: data, as: UTF8.self)
        }
        guard let value = defaults.string(forKey: key) else { return "" }
        try write(Data(value.utf8), account)
        defaults.removeObject(forKey: key)
        return value
    }
    private static func base(_ account: String, _ service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }
}
