import Foundation
import Security
import LocalAuthentication

/// Per owner/subject device-only atomic intent. Target UDID/bundle, credentials,
/// anisette data and private keys are not stored in this journal. Hashing names
/// is not encryption. No fallback, sync, shared group, broad purge or reset API.
struct NativeRegistrationKeychainStore<Client: AppleAccountJournalKeychainClient & Sendable> {
    static var service: String { "com.vexsign.native-signing.registrations.v1" }
    let client: Client

    func read(owner: NativeSigningIdentityOwner, subject: NativeRegistrationSubject) throws -> NativeRegistrationRecord? {
        try requirePrimary()
        var query = base(owner, subject)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext(); context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        let result = client.copy(query)
        if result.status == errSecItemNotFound { return nil }
        guard result.status == errSecSuccess else { throw NativeRegistrationError.storageUnavailable }
        guard let data = result.data, !data.isEmpty, data.count <= 4096 else { throw NativeRegistrationError.invalidJournal }
        do {
            let keys: Set<String> = ["schema", "id", "ownerDigest", "subjectDigest", "createdAt", "phase", "remoteIdentifierDigest"]
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys).isSubset(of: keys) else { throw NativeRegistrationError.invalidJournal }
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
            let record = try decoder.decode(NativeRegistrationRecord.self, from: data)
            try record.validate(owner: owner, subject: subject)
            return record
        } catch { throw NativeRegistrationError.invalidJournal }
    }

    func insertIntent(_ record: NativeRegistrationRecord, owner: NativeSigningIdentityOwner, subject: NativeRegistrationSubject) throws {
        try requirePrimary()
        guard record.phase == .uncertain else { throw NativeRegistrationError.invalidJournal }
        var attributes = base(owner, subject)
        attributes.merge(try values(record, owner, subject)) { _, new in new }
        attributes[kSecAttrGeneric as String] = Data(record.id.uuidString.utf8)
        guard client.add(attributes) == errSecSuccess else { throw NativeRegistrationError.storageUnavailable }
    }

    func recordObservation(_ record: NativeRegistrationRecord, owner: NativeSigningIdentityOwner, subject: NativeRegistrationSubject) throws {
        try requirePrimary()
        guard record.phase == .recorded else { throw NativeRegistrationError.invalidJournal }
        var query = base(owner, subject)
        query[kSecAttrGeneric as String] = Data(record.id.uuidString.utf8)
        query[kSecAttrLabel as String] = NativeRegistrationRecord.Phase.uncertain.rawValue
        guard client.update(query, attributes: try values(record, owner, subject)) == errSecSuccess else {
            throw NativeRegistrationError.storageUnavailable
        }
    }

    private func base(_ owner: NativeSigningIdentityOwner, _ subject: NativeRegistrationSubject) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
         kSecAttrAccount as String: "owner." + owner.digest + ".subject." + subject.digest,
         kSecAttrSynchronizable as String: false]
    }

    private func values(_ record: NativeRegistrationRecord, _ owner: NativeSigningIdentityOwner,
                        _ subject: NativeRegistrationSubject) throws -> [String: Any] {
        try record.validate(owner: owner, subject: subject)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(record), data.count <= 4096 else { throw NativeRegistrationError.invalidJournal }
        return [kSecValueData as String: data, kSecAttrLabel as String: record.phase.rawValue,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
    }

    private func requirePrimary() throws {
        do { try AppleAccountStorageRuntimePolicy.requirePrimaryRuntime() }
        catch { throw NativeRegistrationError.storageUnavailable }
    }
}

extension NativeRegistrationKeychainStore: Sendable where Client: Sendable {}
extension NativeRegistrationKeychainStore: NativeRegistrationStorage {}
