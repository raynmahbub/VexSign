import Foundation

public enum NativeProfileCreationError: Error, Equatable, Sendable {
    case invalidRequest, approvalRequired, busy, inventoryRejected
    case reconciliationRequired, invalidJournal, storageUnavailable, requestFailed
}

/// Internal only. Future bridge must derive validation from the owned identity
/// actor and remote IDs from freshly validated exact device/App ID/cert inventory.
struct NativeOwnedProfileIdentity: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let identityID: UUID
    let certificateIdentifier: String
    let validation: NativeProfileValidationRequest
    var description: String { "NativeOwnedProfileIdentity(redacted)" }
    var debugDescription: String { description }
}

struct NativeProfileCreationRequest: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let identityID: UUID
    let validation: NativeProfileValidationRequest
    let appID: String
    let deviceID: String
    let certificateID: String
    init(identityID: UUID, validation: NativeProfileValidationRequest, appID: String, deviceID: String, certificateID: String) throws {
        guard [appID, deviceID, certificateID].allSatisfy(NativeRegistrationRecord.validIdentifier) else {
            throw NativeProfileCreationError.invalidRequest
        }
        self.identityID = identityID; self.validation = validation
        self.appID = appID; self.deviceID = deviceID; self.certificateID = certificateID
    }
    // Canonical, length-delimited hashing. Remote-ID aliases and bundle casing
    // cannot bypass a pending logical target intent. Exact approval also binds
    // remote IDs, original bundle spelling and an optional selected profile UUID.
    private func hash(_ fields: [String]) -> String {
        var data = Data("VexSign development profile v1\0".utf8)
        for field in fields {
            let bytes = Data(field.utf8); let count = UInt32(bytes.count)
            for shift in stride(from: 24, through: 0, by: -8) { data.append(UInt8((count >> shift) & 255)) }
            data.append(bytes)
        }
        return NativeSigningIdentityOwner.hash(data)
    }
    var digest: String {
        hash([identityID.uuidString, validation.teamIdentifier, validation.bundleIdentifier.lowercased(),
              validation.deviceIdentifier, NativeSigningIdentityOwner.hash(validation.certificateDER)])
    }
    var approvalDigest: String {
        hash([digest, validation.bundleIdentifier, appID, deviceID, certificateID, validation.expectedUUID?.uuidString ?? ""])
    }
    var description: String { "NativeProfileCreationRequest(redacted)" }
    var debugDescription: String { description }
}

struct NativeProfileCreationRecord: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable { case uncertain, recorded }
    let schema: Int
    let id: UUID
    let ownerDigest: String
    let targetDigest: String
    let createdAt: Date
    var phase: Phase
    var remoteIdentifierDigest: String?
    var profileUUID: UUID?
    var cmsSHA256: String?
    func validate(owner: NativeSigningIdentityOwner, request: NativeProfileCreationRequest) throws {
        guard schema == 1, ownerDigest == owner.digest, targetDigest == request.digest,
              owner.teamIdentifier == request.validation.teamIdentifier, createdAt.timeIntervalSince1970.isFinite else {
            throw NativeProfileCreationError.invalidJournal
        }
        switch phase {
        case .uncertain:
            guard remoteIdentifierDigest == nil, profileUUID == nil, cmsSHA256 == nil else { throw NativeProfileCreationError.invalidJournal }
        case .recorded:
            guard remoteIdentifierDigest.map(NativeRegistrationRecord.validDigest) == true, profileUUID != nil,
                  cmsSHA256.map(NativeRegistrationRecord.validDigest) == true else { throw NativeProfileCreationError.invalidJournal }
        }
    }
}

protocol NativeProfileCreationStorage: Sendable {
    func read(owner: NativeSigningIdentityOwner, request: NativeProfileCreationRequest) throws -> NativeProfileCreationRecord?
    func insertIntent(_ record: NativeProfileCreationRecord, owner: NativeSigningIdentityOwner, request: NativeProfileCreationRequest) throws
    func recordObservation(_ record: NativeProfileCreationRecord, owner: NativeSigningIdentityOwner, request: NativeProfileCreationRequest) throws
}

struct NativeProfileObservation: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let remoteIdentifier: String
    let cms: Data
    let listedUUID: UUID?
    init(remoteIdentifier: String, cms: Data, listedUUID: UUID? = nil) {
        self.remoteIdentifier = remoteIdentifier; self.cms = cms; self.listedUUID = listedUUID
    }
    var description: String { "NativeProfileObservation(redacted)" }
    var debugDescription: String { description }
}

/// No production adapter yet. Inventory must be complete for the exact requested
/// target; failed pagination/download/decoding is NOT an empty inventory. Must
/// revalidate free account/team and all remote resource bindings before creation.
/// Creation is limited development, explicit one device/cert/App ID: no update,
/// regenerate, delete, wildcard, distribution, all-device or automatic cleanup.
protocol NativeProfileCreationPortal: Sendable {
    func revalidate(owner: NativeSigningIdentityOwner, contextID: UUID, request: NativeProfileCreationRequest) async throws
    func inventory(request: NativeProfileCreationRequest) async throws -> [NativeProfileObservation]
    func createOnce(request: NativeProfileCreationRequest, operationID: UUID) async throws
}

struct NativeProfileCreationApproval: Equatable, Sendable {
    let id: UUID
    let contextID: UUID
    let ownerDigest: String
    let targetDigest: String
    let epoch: UUID
    let expiresAt: Date
}

struct NativeProfileCreationResult: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let operationID: UUID?
    let profile: NativeAuthenticatedProvisioningProfile
    var description: String { "NativeProfileCreationResult(redacted)" }
    var debugDescription: String { description }
}
