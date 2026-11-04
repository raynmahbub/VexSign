import Foundation

/// One exact registered app/device and durable owned identity. Remote IDs may be
/// taken from registration results but are not authority: fresh exact bindings
/// are checked before portal creation. No caller certificate/CSR/CMS bytes.
public struct NativeAccountProfileTarget: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let identityID: UUID
    let bundleIdentifier: String
    let deviceIdentifier: String
    let appID: String
    let deviceID: String
    let selectedProfileUUID: UUID?

    public init(identityID: UUID, bundleIdentifier: String, deviceIdentifier: String,
                registeredAppID: String, registeredDeviceID: String, selectedProfileUUID: UUID? = nil) throws {
        do {
            _ = try NativeAccountProvisioningRequest(deviceIdentifier: deviceIdentifier, bundleIdentifiers: [bundleIdentifier])
            guard [registeredAppID, registeredDeviceID].allSatisfy(NativeRegistrationRecord.validIdentifier) else {
                throw NativeProfileCreationError.invalidRequest
            }
        } catch { throw NativeProfileCreationError.invalidRequest }
        self.identityID = identityID; self.bundleIdentifier = bundleIdentifier
        self.deviceIdentifier = deviceIdentifier.uppercased()
        appID = registeredAppID; deviceID = registeredDeviceID; self.selectedProfileUUID = selectedProfileUUID
    }
    var approvalDigest: String {
        var data = Data("VexSign account profile target v1\0".utf8)
        for field in [identityID.uuidString, bundleIdentifier, deviceIdentifier, appID, deviceID, selectedProfileUUID?.uuidString ?? ""] {
            let bytes = Data(field.utf8); let count = UInt32(bytes.count)
            for shift in stride(from: 24, through: 0, by: -8) { data.append(UInt8((count >> shift) & 255)) }
            data.append(bytes)
        }
        return NativeSigningIdentityOwner.hash(data)
    }
    public var description: String { "NativeAccountProfileTarget(redacted)" }
    public var debugDescription: String { description }
}

/// Opaque single-use approval, separate from anisette/certificate/registration
/// consent. Contains hashes only; no grant export, extension or journal reset.
public struct NativeAccountProfileApproval: Equatable, Sendable {
    let id: UUID
    let contextID: UUID
    let ownerDigest: String
    let targetDigest: String
    let requestDigest: String
    let flow: UUID
    let epoch: UUID
    let expiresAt: Date
}

/// Public receipt only, not signing readiness or permission to export an identity.
/// Exact authenticated CMS remains internal to the per-worker pipeline.
public struct NativeAccountProfileResult: Sendable {
    public let operationID: UUID?
    public let profileUUID: UUID
    public let expiresAt: Date
}

struct NativeProfileCreationStorageAdapter: NativeProfileCreationStorage {
    let base: any NativeProfileCreationStorage
    func read(owner: NativeSigningIdentityOwner, request: NativeProfileCreationRequest) throws -> NativeProfileCreationRecord? {
        try base.read(owner: owner, request: request)
    }
    func insertIntent(_ record: NativeProfileCreationRecord, owner: NativeSigningIdentityOwner, request: NativeProfileCreationRequest) throws {
        try base.insertIntent(record, owner: owner, request: request)
    }
    func recordObservation(_ record: NativeProfileCreationRecord, owner: NativeSigningIdentityOwner, request: NativeProfileCreationRequest) throws {
        try base.recordObservation(record, owner: owner, request: request)
    }
    func listAllRecords(owner: NativeSigningIdentityOwner) throws -> [NativeProfileCreationRecord] {
        try base.listAllRecords(owner: owner)
    }
}
