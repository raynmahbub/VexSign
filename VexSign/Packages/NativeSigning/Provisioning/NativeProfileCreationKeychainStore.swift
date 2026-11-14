import Foundation
import Security
import LocalAuthentication

/// Per owner/profile-target device-only atomic intent. Target UDID/bundle, credentials,
/// anisette data and private keys are not stored in this journal. Hashing names
/// is not encryption. No fallback, sync, shared group, broad purge or reset API.
struct NativeProfileCreationKeychainStore<Client: AppleAccountJournalKeychainClient> {
    static var service: String { "com.vexsign.native-signing.profiles.v1" }
    let client: Client

    func read(owner: NativeSigningIdentityOwner, request: NativeProfileCreationRequest) throws -> NativeProfileCreationRecord? {
        try requirePrimary()
        var query = base(owner, request)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext(); context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        let result = client.copy(query)
        if result.status == errSecItemNotFound { return nil }
        guard result.status == errSecSuccess else { throw NativeProfileCreationError.storageUnavailable }
        guard let data = result.data, !data.isEmpty, data.count <= 4096 else { throw NativeProfileCreationError.invalidJournal }
        do {
            let keys: Set<String> = ["schema", "id", "ownerDigest", "targetDigest", "createdAt", "phase", "remoteIdentifierDigest", "profileUUID", "cmsSHA256"]
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys).isSubset(of: keys) else { throw NativeProfileCreationError.invalidJournal }
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
            let record = try decoder.decode(NativeProfileCreationRecord.self, from: data)
            try record.validate(owner: owner, request: request)
            return record
        } catch { throw NativeProfileCreationError.invalidJournal }
    }

    func insertIntent(_ record: NativeProfileCreationRecord, owner: NativeSigningIdentityOwner, request: NativeProfileCreationRequest) throws {
        try requirePrimary()
        guard record.phase == .uncertain else { throw NativeProfileCreationError.invalidJournal }
        var attributes = base(owner, request)
        attributes.merge(try values(record, owner, request)) { _, new in new }
        attributes[kSecAttrGeneric as String] = Data(record.id.uuidString.utf8)
        guard client.add(attributes) == errSecSuccess else { throw NativeProfileCreationError.storageUnavailable }
    }

    func recordObservation(_ record: NativeProfileCreationRecord, owner: NativeSigningIdentityOwner, request: NativeProfileCreationRequest) throws {
        try requirePrimary()
        guard record.phase == .recorded else { throw NativeProfileCreationError.invalidJournal }
        var query = base(owner, request)
        query[kSecAttrGeneric as String] = Data(record.id.uuidString.utf8)
        query[kSecAttrLabel as String] = NativeProfileCreationRecord.Phase.uncertain.rawValue
        guard client.update(query, attributes: try values(record, owner, request)) == errSecSuccess else {
            throw NativeProfileCreationError.storageUnavailable
        }
    }

    func listAllRecords(owner: NativeSigningIdentityOwner) throws -> [NativeProfileCreationRecord] {
        try requirePrimary()
        // Query for all items matching the owner prefix
        let ownerPrefix = "owner." + owner.digest + ".target."
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecAttrSynchronizable as String: false
        ]

        let context = LAContext()
        context.interactionNotAllowed = true
        var mutableQuery = query
        mutableQuery[kSecUseAuthenticationContext as String] = context

        let result = client.copyAll(mutableQuery)

        if result.status == errSecItemNotFound {
            return []
        }
        guard result.status == errSecSuccess else { throw NativeProfileCreationError.storageUnavailable }

        // Rows are returned as attribute dictionaries; keep only this owner's
        // rows and decode each one. A corrupt row fails closed, never as an
        // empty journal (same policy as `read`).
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        var records: [NativeProfileCreationRecord] = []
        for item in result.items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  account.hasPrefix(ownerPrefix) else { continue }
            guard let data = item[kSecValueData as String] as? Data,
                  !data.isEmpty, data.count <= 4096,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys).isSubset(of: ["schema", "id", "ownerDigest", "targetDigest", "createdAt", "phase", "remoteIdentifierDigest", "profileUUID", "cmsSHA256"]),
                  let record = try? decoder.decode(NativeProfileCreationRecord.self, from: data),
                  record.schema == 1, record.ownerDigest == owner.digest,
                  record.createdAt.timeIntervalSince1970.isFinite,
                  (record.phase == .uncertain && record.remoteIdentifierDigest == nil && record.profileUUID == nil && record.cmsSHA256 == nil)
                    || (record.phase == .recorded && record.remoteIdentifierDigest.map(NativeRegistrationRecord.validDigest) == true
                        && record.profileUUID != nil && record.cmsSHA256.map(NativeRegistrationRecord.validDigest) == true)
            else { throw NativeProfileCreationError.invalidJournal }
            records.append(record)
        }
        return records
    }

    private func base(_ owner: NativeSigningIdentityOwner, _ request: NativeProfileCreationRequest) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
         kSecAttrAccount as String: "owner." + owner.digest + ".target." + request.digest,
         kSecAttrSynchronizable as String: false]
    }

    private func values(_ record: NativeProfileCreationRecord, _ owner: NativeSigningIdentityOwner,
                        _ request: NativeProfileCreationRequest) throws -> [String: Any] {
        try record.validate(owner: owner, request: request)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(record), data.count <= 4096 else { throw NativeProfileCreationError.invalidJournal }
        return [kSecValueData as String: data, kSecAttrLabel as String: record.phase.rawValue,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
    }

    private func requirePrimary() throws {
        do { try AppleAccountStorageRuntimePolicy.requirePrimaryRuntime() }
        catch { throw NativeProfileCreationError.storageUnavailable }
    }
}

extension NativeProfileCreationKeychainStore: Sendable where Client: Sendable {}
extension NativeProfileCreationKeychainStore: NativeProfileCreationStorage {}
