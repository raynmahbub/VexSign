import Foundation
import Security
import LocalAuthentication

/// One device-only atomic blob per account/team owner. No access group, sync,
/// preferences fallback, broad purge, certificate revocation or session storage.
struct NativeSigningIdentityKeychainStore<Client: AppleAccountJournalKeychainClient & Sendable> {
    static var service: String { "com.vexsign.native-signing.identities.v1" }
    static var maximumBytes: Int { 256 * 1024 }
    let client: Client

    func read(owner: NativeSigningIdentityOwner) throws -> NativeSigningIdentityRecord? {
        try requirePrimary()
        var query = base(owner)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        let result = client.copy(query)
        if result.status == errSecItemNotFound { return nil }
        guard result.status == errSecSuccess else { throw NativeSigningIdentityError.storageUnavailable }
        guard let data = result.data, !data.isEmpty, data.count <= Self.maximumBytes else {
            throw NativeSigningIdentityError.invalidRecord
        }
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys).isSubset(of: Set(NativeSigningIdentityRecord.CodingKeys.allCases.map(\.rawValue))) else {
                throw NativeSigningIdentityError.invalidRecord
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            let record = try decoder.decode(NativeSigningIdentityRecord.self, from: data)
            try record.validateShape(owner: owner)
            try NativeSigningIdentityCrypto.validateMaterial(record)
            return record
        } catch { throw NativeSigningIdentityError.invalidRecord }
    }

    func insert(_ record: NativeSigningIdentityRecord, owner: NativeSigningIdentityOwner) throws {
        try requirePrimary()
        guard record.phase == .prepared else { throw NativeSigningIdentityError.invalidRecord }
        var attributes = base(owner)
        attributes.merge(try values(record, owner: owner)) { _, new in new }
        attributes[kSecAttrGeneric as String] = Data(record.id.uuidString.utf8)
        guard client.add(attributes) == errSecSuccess else { throw NativeSigningIdentityError.storageUnavailable }
    }

    func replace(_ record: NativeSigningIdentityRecord, owner: NativeSigningIdentityOwner) throws {
        try requirePrimary()
        let previous: NativeSigningIdentityPhase
        switch record.phase {
        case .submissionUncertain: previous = .prepared
        case .certificateRecorded: previous = .submissionUncertain
        case .prepared: throw NativeSigningIdentityError.invalidRecord // never reset uncertain intent
        }
        var query = base(owner)
        query[kSecAttrGeneric as String] = Data(record.id.uuidString.utf8)
        // Keychain update is conditional on BOTH operation ID and previous phase.
        // A stale writer cannot reset/delete an already submitted identity.
        query[kSecAttrLabel as String] = previous.rawValue
        guard client.update(query, attributes: try values(record, owner: owner)) == errSecSuccess else {
            throw NativeSigningIdentityError.storageUnavailable
        }
    }

    func deletePrepared(_ record: NativeSigningIdentityRecord, owner: NativeSigningIdentityOwner) throws {
        try requirePrimary()
        try record.validateShape(owner: owner)
        guard record.phase == .prepared else { throw NativeSigningIdentityError.cannotDiscardSubmittedIdentity }
        var query = base(owner)
        query[kSecAttrGeneric as String] = Data(record.id.uuidString.utf8)
        query[kSecAttrLabel as String] = NativeSigningIdentityPhase.prepared.rawValue
        // Not-found can mean it advanced to uncertain; do not call that success.
        guard client.delete(query) == errSecSuccess else { throw NativeSigningIdentityError.storageUnavailable }
    }

    private func values(_ record: NativeSigningIdentityRecord, owner: NativeSigningIdentityOwner) throws -> [String: Any] {
        try record.validateShape(owner: owner)
        try NativeSigningIdentityCrypto.validateMaterial(record)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(record), data.count <= Self.maximumBytes else {
            throw NativeSigningIdentityError.invalidRecord
        }
        return [kSecValueData as String: data,
                kSecAttrLabel as String: record.phase.rawValue,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
    }

    private func base(_ owner: NativeSigningIdentityOwner) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: "owner." + owner.digest,
         kSecAttrSynchronizable as String: false]
    }

    private func requirePrimary() throws {
        do { try AppleAccountStorageRuntimePolicy.requirePrimaryRuntime() }
        catch { throw NativeSigningIdentityError.storageUnavailable }
    }
}

extension NativeSigningIdentityKeychainStore: Sendable {}
extension NativeSigningIdentityKeychainStore: NativeSigningIdentityStorage {}
