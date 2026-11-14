import Foundation
import Security
import LocalAuthentication

/// Renewal discovery metadata, not signing authority. This is a separate,
/// device-only Keychain index: the mutation journal remains hash-only.
struct NativeProfileReceipt: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    var description: String { "NativeProfileReceipt(redacted)" }
    var debugDescription: String { description }
    let schema: Int
    let ownerDigest: String
    let targetDigest: String
    let identityID: UUID
    let profileUUID: UUID
    let cmsSHA256: String
    let certificateSHA256: String
    let bundleIdentifier: String
    let deviceIdentifier: String
    let expiresAt: Date
    let recordedAt: Date

    init(profile: NativeAuthenticatedProvisioningProfile, owner: NativeSigningIdentityOwner,
         request: NativeProfileCreationRequest, recordedAt: Date) throws {
        guard profile.constraints.teamIdentifier == owner.teamIdentifier,
              profile.constraints.applicationIdentifier == owner.teamIdentifier + "." + request.validation.bundleIdentifier,
              profile.deviceIdentifier == request.validation.deviceIdentifier,
              profile.certificateSHA256 == NativeSigningIdentityOwner.hash(request.validation.certificateDER),
              profile.constraints.expiresAt > recordedAt else { throw NativeProfileCreationError.invalidJournal }
        schema = 1; ownerDigest = owner.digest; targetDigest = request.digest
        identityID = request.identityID; profileUUID = profile.constraints.uuid
        cmsSHA256 = profile.cmsSHA256; certificateSHA256 = profile.certificateSHA256
        bundleIdentifier = request.validation.bundleIdentifier
        deviceIdentifier = request.validation.deviceIdentifier
        expiresAt = profile.constraints.expiresAt; self.recordedAt = recordedAt
        try validate(owner: owner)
    }
    func validate(owner: NativeSigningIdentityOwner) throws {
        guard schema == 1, ownerDigest == owner.digest,
              [ownerDigest, targetDigest, cmsSHA256, certificateSHA256].allSatisfy(NativeRegistrationRecord.validDigest),
              expiresAt.timeIntervalSince1970.isFinite, recordedAt.timeIntervalSince1970.isFinite,
              recordedAt >= Date.distantPast, expiresAt <= Date.distantFuture,
              expiresAt > recordedAt else { throw NativeProfileCreationError.invalidJournal }
        do { _ = try NativeAccountProvisioningRequest(deviceIdentifier: deviceIdentifier, bundleIdentifiers: [bundleIdentifier]) }
        catch { throw NativeProfileCreationError.invalidJournal }
    }
    /// Reconciliation may observe the same authenticated envelope again later.
    func sameProfile(as other: Self) -> Bool {
        schema == other.schema && ownerDigest == other.ownerDigest && targetDigest == other.targetDigest
            && identityID == other.identityID && profileUUID == other.profileUUID && cmsSHA256 == other.cmsSHA256
            && certificateSHA256 == other.certificateSHA256 && bundleIdentifier == other.bundleIdentifier
            && deviceIdentifier == other.deviceIdentifier && expiresAt == other.expiresAt
    }
}

protocol NativeProfileReceiptStorage: Sendable {
    func record(_ receipt: NativeProfileReceipt, owner: NativeSigningIdentityOwner) throws
    func list(owner: NativeSigningIdentityOwner) throws -> [NativeProfileReceipt]
}

/// Add-only history. Duplicates must match the exact authenticated receipt;
/// changes require a different profile UUID, not an overwrite/reset/purge.
struct NativeProfileReceiptKeychainStore<Client: AppleAccountJournalKeychainClient & Sendable>: NativeProfileReceiptStorage {
    let client: Client
    static var service: String { "com.vexsign.native-signing.profile-receipts.v1" }
    private func account(_ receipt: NativeProfileReceipt) -> String {
        "owner." + receipt.ownerDigest + ".profile." + receipt.profileUUID.uuidString
    }
    private var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
         kSecAttrSynchronizable as String: false]
    }
    func record(_ receipt: NativeProfileReceipt, owner: NativeSigningIdentityOwner) throws {
        try AppleAccountStorageRuntimePolicy.requirePrimaryRuntime()
        try receipt.validate(owner: owner)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(receipt)
        guard data.count <= 4096 else { throw NativeProfileCreationError.invalidJournal }
        var attributes = base
        attributes[kSecAttrAccount as String] = account(receipt)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        attributes[kSecValueData as String] = data
        let status = client.add(attributes)
        if status == errSecDuplicateItem {
            // Query the exact row, never accept an unrelated same-owner receipt.
            attributes = base
            attributes[kSecAttrAccount as String] = account(receipt)
            attributes[kSecReturnData as String] = true
            attributes[kSecMatchLimit as String] = kSecMatchLimitOne
            let context = LAContext(); context.interactionNotAllowed = true
            attributes[kSecUseAuthenticationContext as String] = context
            let result = client.copy(attributes)
            guard result.status == errSecSuccess, let data = result.data else { throw NativeProfileCreationError.storageUnavailable }
            let previous = try decode(data, owner: owner)
            guard previous.sameProfile(as: receipt) else { throw NativeProfileCreationError.reconciliationRequired }
        } else if status != errSecSuccess { throw NativeProfileCreationError.storageUnavailable }
    }
    func list(owner: NativeSigningIdentityOwner) throws -> [NativeProfileReceipt] {
        try AppleAccountStorageRuntimePolicy.requirePrimaryRuntime()
        var query = base
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        let context = LAContext(); context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        let result = client.copyAll(query)
        if result.status == errSecItemNotFound { return [] }
        guard result.status == errSecSuccess else { throw NativeProfileCreationError.storageUnavailable }
        guard result.items.count <= 512 else { throw NativeProfileCreationError.invalidJournal }
        var receipts: [NativeProfileReceipt] = []
        for item in result.items {
            guard let key = item[kSecAttrAccount as String] as? String,
                  key.hasPrefix("owner." + owner.digest + ".profile.") else { continue }
            guard let data = item[kSecValueData as String] as? Data else { throw NativeProfileCreationError.invalidJournal }
            let receipt = try decode(data, owner: owner)
            guard key == account(receipt) else { throw NativeProfileCreationError.invalidJournal }
            receipts.append(receipt)
        }
        guard Set(receipts.map(\.profileUUID)).count == receipts.count else { throw NativeProfileCreationError.invalidJournal }
        return receipts.sorted { $0.profileUUID.uuidString < $1.profileUUID.uuidString }
    }
    private func decode(_ data: Data, owner: NativeSigningIdentityOwner) throws -> NativeProfileReceipt {
        guard !data.isEmpty, data.count <= 4096 else { throw NativeProfileCreationError.invalidJournal }
        do {
            let keys: Set<String> = ["schema", "ownerDigest", "targetDigest", "identityID", "profileUUID", "cmsSHA256",
                                     "certificateSHA256", "bundleIdentifier", "deviceIdentifier", "expiresAt", "recordedAt"]
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys) == keys else { throw NativeProfileCreationError.invalidJournal }
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
            let receipt = try decoder.decode(NativeProfileReceipt.self, from: data)
            try receipt.validate(owner: owner)
            return receipt
        } catch { throw NativeProfileCreationError.invalidJournal }
    }
}
