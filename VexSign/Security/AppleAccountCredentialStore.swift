import Foundation
import Security
import LocalAuthentication

enum AppleAccountCredentialStoreError: LocalizedError, Equatable {
    case unsupportedGuestRuntime
    case invalidSessionSize
    case invalidStoredSession
    case keychainStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unsupportedGuestRuntime:
            return NSLocalizedString("Account session storage is disabled in the experimental guest-host build.", comment: "")
        case .invalidSessionSize:
            return NSLocalizedString("The account session could not be stored because its size is invalid.", comment: "")
        case .invalidStoredSession:
            return NSLocalizedString("Secure account storage returned an invalid session record. Reauthenticate rather than treating it as a missing account.", comment: "")
        case .keychainStatus(let status):
            return String(format: NSLocalizedString("Secure account storage failed (status %d). Unlock the device and retry; the account was not silently reset.", comment: ""), arguments: [status])
        }
    }
}

/// Synchronous Security calls, injectable without Sendable escape hatches.
/// Production values can be sent to a worker task; test clients can remain local.
protocol AppleAccountKeychainClient {
    func add(_ attributes: [String: Any]) -> OSStatus
    func copy(_ query: [String: Any]) -> (status: OSStatus, data: Data?)
    func delete(_ query: [String: Any]) -> OSStatus
}

struct SystemAppleAccountKeychainClient: AppleAccountKeychainClient, Sendable {
    func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func copy(_ query: [String: Any]) -> (status: OSStatus, data: Data?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

/// Session bytes only: no Apple-password API, preferences, backup file, shared
/// access group, account-name label or remote transport. The native adapter must
/// serialize the SDK's session, never pass a password here. This store does not
/// authenticate, provision, or make the account signing backend available.
struct AppleAccountCredentialStore<Client: AppleAccountKeychainClient> {
    static var service: String { "com.vexsign.apple-account.sessions.v1" }
    static var maximumSessionBytes: Int { 1024 * 1024 }
    private let client: Client

    init(client: Client) { self.client = client }

    /// Add-only: duplicate references fail; a late login cannot overwrite another
    /// operation's accepted session. Callers generate a new UUID per transaction.
    @discardableResult
    func insertSession(_ sessionData: Data, reference: UUID = UUID()) throws -> UUID {
        try checkEnvironment()
        guard !sessionData.isEmpty, sessionData.count <= Self.maximumSessionBytes else {
            throw AppleAccountCredentialStoreError.invalidSessionSize
        }
        var attributes = base(reference)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        attributes[kSecValueData as String] = sessionData
        let status = client.add(attributes)
        guard status == errSecSuccess else { throw AppleAccountCredentialStoreError.keychainStatus(status) }
        return reference
    }

    /// Only not-found means absent. Locked storage, entitlement errors and corrupt
    /// replies must not be converted into a silent sign-out or a nil session.
    func readSession(reference: UUID) throws -> Data? {
        try checkEnvironment()
        var query = base(reference)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        let result = client.copy(query)
        if result.status == errSecItemNotFound { return nil }
        guard result.status == errSecSuccess else {
            throw AppleAccountCredentialStoreError.keychainStatus(result.status)
        }
        guard let data = result.data, !data.isEmpty, data.count <= Self.maximumSessionBytes else {
            throw AppleAccountCredentialStoreError.invalidStoredSession
        }
        return data
    }

    /// Exact record deletion, not a service-wide purge or portal revocation.
    func deleteSession(reference: UUID) throws {
        try checkEnvironment()
        let status = client.delete(base(reference))
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AppleAccountCredentialStoreError.keychainStatus(status)
        }
    }

    private func base(_ reference: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: "session." + reference.uuidString,
         kSecAttrSynchronizable as String: false]
    }

    private func checkEnvironment() throws {
        // A compatibility guard, not an OS sandbox/security boundary.
        try AppleAccountStorageRuntimePolicy.requirePrimaryRuntime()
    }
}

extension AppleAccountCredentialStore: Sendable where Client: Sendable {}

extension AppleAccountCredentialStore where Client == SystemAppleAccountKeychainClient {
    init() { self.init(client: SystemAppleAccountKeychainClient()) }
}

// Platform-specific conformances stay out of the Foundation-only lifecycle core.
extension AppleAccountCredentialStore: AppleAccountSessionStorage where Client: Sendable {}
extension AppleAccountCredentialStore: AppleAccountRecoverableSessionStorage where Client: Sendable {}
