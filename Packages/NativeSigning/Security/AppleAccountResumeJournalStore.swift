import Foundation
import Security
import LocalAuthentication

protocol AppleAccountJournalKeychainClient: AppleAccountKeychainClient {
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    /// All matching rows for a `kSecMatchLimitAll` query, each row's
    /// attributes (including `kSecValueData`) as one dictionary.
    func copyAll(_ query: [String: Any]) -> (status: OSStatus, items: [[String: Any]])
}

extension AppleAccountJournalKeychainClient {
    /// Clients without enumeration support must fail closed, not turn a
    /// single-row read or unavailable inventory into a successful empty list.
    func copyAll(_ query: [String: Any]) -> (status: OSStatus, items: [[String: Any]]) {
        (errSecUnimplemented, [])
    }
}

extension SystemAppleAccountKeychainClient: AppleAccountJournalKeychainClient {
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    func copyAll(_ query: [String: Any]) -> (status: OSStatus, items: [[String: Any]]) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return (status, []) }
        guard let items = result as? [[String: Any]] else { return (errSecDecode, []) }
        return (status, items)
    }
}

/// The fixed journal row is updatable; session rows remain insert-only in their
/// separate service. Locked/inaccessible/corrupt storage never becomes an empty
/// journal. No preferences fallback or service-wide delete operation exists.
struct AppleAccountResumeJournalStore<Client: AppleAccountJournalKeychainClient> {
    static var service: String { "com.vexsign.apple-account.resume-journal.v1" }
    static var maximumBytes: Int { 16 * 1024 }
    private let client: Client

    init(client: Client) { self.client = client }

    func readJournal() throws -> AppleAccountResumeJournal? {
        try checkEnvironment()
        var query = base
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
        guard let data = result.data, !data.isEmpty, data.count <= Self.maximumBytes else {
            throw AppleAccountSessionRepositoryError.invalidJournal
        }
        let journal: AppleAccountResumeJournal
        do {
            guard let dictionary = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(dictionary.keys).isSubset(of: Set(AppleAccountResumeJournal.CodingKeys.allCases.map(\.rawValue))) else {
                throw AppleAccountSessionRepositoryError.invalidJournal
            }
            journal = try JSONDecoder().decode(AppleAccountResumeJournal.self, from: data)
        } catch {
            // Normalize decoding failures: never log Keychain bytes or expose
            // arbitrary decoder payload descriptions through user-facing errors.
            throw AppleAccountSessionRepositoryError.invalidJournal
        }
        try journal.validate()
        return journal
    }

    func writeJournal(_ journal: AppleAccountResumeJournal) throws {
        try checkEnvironment()
        try journal.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(journal)
        guard data.count <= Self.maximumBytes else { throw AppleAccountSessionRepositoryError.invalidJournal }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = client.update(base, attributes: attributes)
        if status == errSecItemNotFound {
            let insert = base.merging(attributes) { _, new in new }
            let added = client.add(insert)
            guard added == errSecSuccess else { throw AppleAccountCredentialStoreError.keychainStatus(added) }
        } else if status != errSecSuccess {
            throw AppleAccountCredentialStoreError.keychainStatus(status)
        }
    }

    private var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: "primary",
         kSecAttrSynchronizable as String: false]
    }

    private func checkEnvironment() throws {
        try AppleAccountStorageRuntimePolicy.requirePrimaryRuntime()
    }
}

extension AppleAccountResumeJournalStore: Sendable where Client: Sendable {}
extension AppleAccountResumeJournalStore: AppleAccountResumeJournalStorage {}

extension AppleAccountResumeJournalStore where Client == SystemAppleAccountKeychainClient {
    init() { self.init(client: SystemAppleAccountKeychainClient()) }
}
