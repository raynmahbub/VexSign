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
    func recordRenewal(_ receipt: NativeProfileReceipt, replacing baselineDigest: String, owner: NativeSigningIdentityOwner) throws
}

extension NativeProfileReceiptStorage {
    func recordRenewal(_ receipt: NativeProfileReceipt, replacing baselineDigest: String, owner: NativeSigningIdentityOwner) throws {
        throw NativeProfileCreationError.storageUnavailable // unsupported stores cannot accept renewal
    }
}

/// Add-only history. Normal observations cannot change an existing receipt.
/// A confirmed same-UUID renewal adds one successor keyed by the previous CMS digest.
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
        try insert(receipt, key: account(receipt), owner: owner)
    }

    func recordRenewal(_ receipt: NativeProfileReceipt, replacing baselineDigest: String, owner: NativeSigningIdentityOwner) throws {
        try receipt.validate(owner: owner)
        let current = try list(owner: owner)
        guard let previous = current.first(where: { $0.cmsSHA256 == baselineDigest }),
              Self.advances(previous, to: receipt) else { throw NativeProfileCreationError.reconciliationRequired }
        if previous.profileUUID != receipt.profileUUID {
            try record(receipt, owner: owner)
        } else {
            try insert(receipt, key: account(receipt) + ".after." + baselineDigest, owner: owner)
        }
    }

    private static func advances(_ old: NativeProfileReceipt, to new: NativeProfileReceipt) -> Bool {
        old.ownerDigest == new.ownerDigest && old.targetDigest == new.targetDigest && old.identityID == new.identityID
            && old.bundleIdentifier == new.bundleIdentifier && old.deviceIdentifier == new.deviceIdentifier
            && old.certificateSHA256 == new.certificateSHA256 && old.cmsSHA256 != new.cmsSHA256
            && old.expiresAt < new.expiresAt
    }

    private func insert(_ receipt: NativeProfileReceipt, key: String, owner: NativeSigningIdentityOwner) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(receipt)
        guard data.count <= 4096 else { throw NativeProfileCreationError.invalidJournal }
        var attributes = base
        attributes[kSecAttrAccount as String] = key
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        attributes[kSecValueData as String] = data
        let status = client.add(attributes)
        if status == errSecDuplicateItem {
            // Query the exact row, never accept an unrelated same-owner receipt.
            attributes = base
            attributes[kSecAttrAccount as String] = key
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
        var successors: [String: NativeProfileReceipt] = [:]
        for item in result.items {
            guard let key = item[kSecAttrAccount as String] as? String,
                  key.hasPrefix("owner." + owner.digest + ".profile.") else { continue }
            guard let data = item[kSecValueData as String] as? Data else { throw NativeProfileCreationError.invalidJournal }
            let receipt = try decode(data, owner: owner)
            let prefix = account(receipt) + ".after."
            if key == account(receipt) {
                receipts.append(receipt)
            } else if key.hasPrefix(prefix), NativeRegistrationRecord.validDigest(String(key.dropFirst(prefix.count))),
                      successors.updateValue(receipt, forKey: key) == nil {
                continue
            } else { throw NativeProfileCreationError.invalidJournal }
        }
        guard Set(receipts.map(\.profileUUID)).count == receipts.count else { throw NativeProfileCreationError.invalidJournal }
        for index in receipts.indices {
            var current = receipts[index]
            while let next = successors.removeValue(forKey: account(current) + ".after." + current.cmsSHA256) {
                guard Self.advances(current, to: next) else { throw NativeProfileCreationError.invalidJournal }
                current = next
            }
            receipts[index] = current
        }
        guard successors.isEmpty else { throw NativeProfileCreationError.invalidJournal }
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

/// Separate from profile creation approval. Prepare a review for an exact authenticated
/// inventory row; only confirm from the user's affirmative renewal action. A returned
/// operation ID means the attempt is already journaled, NOT that Apple renewed anything.
actor NativeProfileRenewalGate<Client: AppleAccountJournalKeychainClient & Sendable> {
    struct Review: Equatable, Sendable {
        fileprivate let nonce: UUID
        fileprivate let context: UUID
        fileprivate let ownerDigest: String
        fileprivate let targetDigest: String
        fileprivate let baselineDigest: String
        fileprivate let remoteID: String
        fileprivate let deadline: Date
        let bundleIdentifier: String
        let originalExpiry: Date
    }

    private let client: Client
    private let clock: @Sendable () -> Date
    private var pending: Review?
    init(client: Client, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client; self.clock = clock
    }

    func review(context: UUID, owner: NativeSigningIdentityOwner, request: NativeProfileCreationRequest,
                remoteID: String, baseline: NativeAuthenticatedProvisioningProfile) throws -> Review {
        pending = nil
        try Task.checkCancellation()
        let now = clock()
        guard now.timeIntervalSince1970.isFinite, NativeRegistrationRecord.validIdentifier(remoteID),
              baseline.constraints.teamIdentifier == owner.teamIdentifier,
              request.validation.teamIdentifier == owner.teamIdentifier,
              baseline.constraints.applicationIdentifier == owner.teamIdentifier + "." + request.validation.bundleIdentifier,
              baseline.deviceIdentifier == request.validation.deviceIdentifier,
              baseline.certificateSHA256 == NativeSigningIdentityOwner.hash(request.validation.certificateDER),
              request.validation.expectedUUID.map({ $0 == baseline.constraints.uuid }) ?? true else {
            throw NativeProfileCreationError.invalidRequest
        }
        let review = Review(nonce: UUID(), context: context, ownerDigest: owner.digest,
            targetDigest: request.approvalDigest, baselineDigest: baseline.cmsSHA256, remoteID: remoteID,
            deadline: now.addingTimeInterval(120), bundleIdentifier: request.validation.bundleIdentifier,
            originalExpiry: baseline.constraints.expiresAt)
        pending = review
        return review
    }

    func cancel() { pending = nil }

    /// Caller revalidates the live owner, portal row and authenticated CMS immediately
    /// before confirmation. Atomic Keychain insertion also excludes racing processes.
    func confirm(_ review: Review, context: UUID, owner: NativeSigningIdentityOwner,
                 request: NativeProfileCreationRequest, remoteID: String,
                 baseline: NativeAuthenticatedProvisioningProfile) throws -> UUID {
        guard pending == review else { throw NativeProfileCreationError.approvalRequired }
        pending = nil
        try Task.checkCancellation()
        let now = clock()
        guard review.context == context, review.ownerDigest == owner.digest,
              review.targetDigest == request.approvalDigest, review.remoteID == remoteID,
              review.baselineDigest == baseline.cmsSHA256, now < review.deadline,
              now >= review.deadline.addingTimeInterval(-120) else { throw NativeProfileCreationError.approvalRequired }
        try AppleAccountStorageRuntimePolicy.requirePrimaryRuntime()
        let operation = UUID()
        let status = client.add([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.vexsign.native-signing.renewal-intent.v1",
            kSecAttrAccount as String: owner.digest + "." + baseline.cmsSHA256,
            kSecAttrSynchronizable as String: false,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: Data(operation.uuidString.utf8)
        ])
        if status == errSecDuplicateItem { throw NativeProfileCreationError.reconciliationRequired }
        guard status == errSecSuccess else { throw NativeProfileCreationError.storageUnavailable }
        try Task.checkCancellation() // Never clear the intent on an uncertain outcome.
        return operation
    }
}
