import Foundation
import CryptoKit

public enum NativeSigningIdentityError: Error, Equatable, Sendable {
    case invalidRecord, storageUnavailable, generationFailed, contextChanged, busy
    case identityChanged, reconciliationRequired, certificateRejected, cannotDiscardSubmittedIdentity
    case creationApprovalRequired, certificateRequestFailed
}

public enum NativeSigningIdentityPhase: String, Codable, Equatable, Sendable {
    case prepared, submissionUncertain, certificateRecorded
}

/// Metadata only. A recorded certificate is NOT proof of Apple trust, permitted
/// entitlements, a usable profile or signing readiness. No key/CSR export API.
public struct NativeSigningIdentityTicket: Equatable, Sendable {
    public let id: UUID
    public let teamIdentifier: String
    public let phase: NativeSigningIdentityPhase
    public let publicKeySHA256: String
    public let csrSHA256: String
}

/// Historical local metadata only; not proof of current certificate trust or
/// permission to sign/export. Reading inventory never prepares/rotates a key.
public struct NativeSigningIdentityInfo: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let ticket: NativeSigningIdentityTicket
    public let certificateSHA256: String?
    public let certificateExpiresAt: Date?
    public var description: String { "NativeSigningIdentityInfo(redacted)" }
    public var debugDescription: String { description }
}

struct NativeSigningIdentityOwner: Equatable, Sendable {
    let digest: String
    let teamIdentifier: String

    init(accountIdentifier: String, dsid: String, teamIdentifier: String) throws {
        let fields = [accountIdentifier, dsid, teamIdentifier]
        guard fields.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 65_536
            && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }),
              teamIdentifier.utf8.count <= 256 else { throw NativeSigningIdentityError.invalidRecord }
        // Fixed UTF-8 domain + big-endian length prefixes are stable across
        // JSON encoder/OS changes and prevent ambiguous concatenation. No email/
        // token enters the Keychain account label; hashing is NOT encryption.
        var bytes = Data("VexSign signing identity v1\0".utf8)
        for field in fields {
            let value = Data(field.utf8)
            let size = UInt32(value.count)
            for shift in stride(from: 24, through: 0, by: -8) {
                bytes.append(UInt8((size >> shift) & 255))
            }
            bytes.append(value)
        }
        digest = Self.hash(bytes)
        self.teamIdentifier = teamIdentifier
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// One atomically updated row contains BOTH key ownership and submission intent.
/// No Apple password, session token, anisette snapshot or OTP is stored here.
struct NativeSigningIdentityRecord: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let schema: Int
    let ownerDigest: String
    let teamIdentifier: String
    let id: UUID
    let createdAt: Date
    let privateKeyDER: Data
    let publicKeyDER: Data
    let csrDER: Data
    var phase: NativeSigningIdentityPhase
    var certificateDER: Data?
    var certificateIdentifier: String?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case schema, ownerDigest, teamIdentifier, id, createdAt
        case privateKeyDER, publicKeyDER, csrDER, phase, certificateDER, certificateIdentifier
    }
    var description: String { "NativeSigningIdentityRecord(redacted)" }
    var debugDescription: String { description }
    var machineName: String { "VexSign-" + id.uuidString }
    var ticket: NativeSigningIdentityTicket {
        NativeSigningIdentityTicket(id: id, teamIdentifier: teamIdentifier, phase: phase,
            publicKeySHA256: NativeSigningIdentityOwner.hash(publicKeyDER),
            csrSHA256: NativeSigningIdentityOwner.hash(csrDER))
    }

    func validateShape(owner: NativeSigningIdentityOwner) throws {
        guard schema == 1, ownerDigest == owner.digest, teamIdentifier == owner.teamIdentifier,
              createdAt.timeIntervalSince1970.isFinite,
              !privateKeyDER.isEmpty, privateKeyDER.count <= 32 * 1024,
              !publicKeyDER.isEmpty, publicKeyDER.count <= 8 * 1024,
              !csrDER.isEmpty, csrDER.count <= 32 * 1024 else { throw NativeSigningIdentityError.invalidRecord }
        switch phase {
        case .prepared, .submissionUncertain:
            guard certificateDER == nil, certificateIdentifier == nil else { throw NativeSigningIdentityError.invalidRecord }
        case .certificateRecorded:
            guard let certificateDER, !certificateDER.isEmpty, certificateDER.count <= 64 * 1024,
                  let identifier = certificateIdentifier, !identifier.isEmpty, identifier.utf8.count <= 256,
                  identifier.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }) else {
                throw NativeSigningIdentityError.invalidRecord
            }
        }
    }
}

protocol NativeSigningIdentityStorage: Sendable {
    func read(owner: NativeSigningIdentityOwner) throws -> NativeSigningIdentityRecord?
    func insert(_ record: NativeSigningIdentityRecord, owner: NativeSigningIdentityOwner) throws
    func replace(_ record: NativeSigningIdentityRecord, owner: NativeSigningIdentityOwner) throws
    func deletePrepared(_ record: NativeSigningIdentityRecord, owner: NativeSigningIdentityOwner) throws
}

protocol NativeSigningIdentityGenerating: Sendable {
    func generate(owner: NativeSigningIdentityOwner, id: UUID, now: Date) throws -> NativeSigningIdentityRecord
}

/// CSR-only material for a FUTURE internal executor. No private key. Obtain only
/// AFTER durable uncertain intent; never pass to an anisette provider or UI.
struct NativeSigningCSRSubmission: Sendable {
    let identityID: UUID
    let machineName: String
    let csrDER: Data
}

/// Sanitized inventory input for matching an uncertain request. A future portal
/// adapter must obtain this under the original account/team's fresh authority.
struct NativeSigningCertificateObservation: Sendable {
    let identifier: String
    let certificateDER: Data
}

/// Internal injection seam for the bridge's real durable owner and deterministic
/// coding-phase fixtures. Implementations must persist intent before releasing CSR.
struct NativeOwnedSigningCertificate: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let identityID: UUID
    let certificateIdentifier: String
    let certificateDER: Data
    var description: String { "NativeOwnedSigningCertificate(redacted)" }
    var debugDescription: String { description }
}

protocol NativeSigningIdentityManaging: Actor {
    func localIdentity(owner: NativeSigningIdentityOwner, now: Date) async throws -> NativeSigningIdentityInfo?
    func ownedSigningCertificate(owner: NativeSigningIdentityOwner, identityID: UUID, now: Date) async throws -> NativeOwnedSigningCertificate
    func prepare(owner: NativeSigningIdentityOwner, now: Date) async throws -> NativeSigningIdentityTicket
    func ticket(owner: NativeSigningIdentityOwner, identityID: UUID) async throws -> NativeSigningIdentityTicket
    func beginSubmission(owner: NativeSigningIdentityOwner, identityID: UUID) async throws -> NativeSigningCSRSubmission
    func recordCertificate(owner: NativeSigningIdentityOwner, identityID: UUID, certificateDER: Data,
                           certificateIdentifier: String, now: Date) async throws -> NativeSigningIdentityTicket
    func reconcileUncertain(owner: NativeSigningIdentityOwner, identityID: UUID,
                            certificates: [NativeSigningCertificateObservation], now: Date) async throws -> NativeSigningIdentityTicket
    func discardPrepared(owner: NativeSigningIdentityOwner, identityID: UUID) async throws
    func profileValidationRequest(owner: NativeSigningIdentityOwner, identityID: UUID, bundleIdentifier: String,
                                  deviceIdentifier: String, now: Date) async throws -> NativeProfileValidationRequest
    func ownedProfileIdentity(owner: NativeSigningIdentityOwner, identityID: UUID, bundleIdentifier: String,
                              deviceIdentifier: String, now: Date) async throws -> NativeOwnedProfileIdentity

    /// Retrieves the private key DER for the given identity.
    /// Only available for identities in .prepared or .certificateRecorded phase.
    /// Requires explicit key export consent (handled by caller).
    func privateKeyDER(owner: NativeSigningIdentityOwner, identityID: UUID, now: Date) async throws -> Data
}

extension NativeSigningIdentityManaging {
    func localIdentity(owner: NativeSigningIdentityOwner, now: Date) async throws -> NativeSigningIdentityInfo? {
        throw NativeSigningIdentityError.storageUnavailable
    }

    func ownedSigningCertificate(owner: NativeSigningIdentityOwner, identityID: UUID, now: Date) async throws -> NativeOwnedSigningCertificate {
        throw NativeSigningIdentityError.reconciliationRequired
    }
    func ownedProfileIdentity(owner: NativeSigningIdentityOwner, identityID: UUID, bundleIdentifier: String,
                              deviceIdentifier: String, now: Date) async throws -> NativeOwnedProfileIdentity {
        throw NativeSigningIdentityError.reconciliationRequired
    }

    // State-only fixtures cannot silently pretend they own a usable certificate.
    func profileValidationRequest(owner: NativeSigningIdentityOwner, identityID: UUID, bundleIdentifier: String,
                                  deviceIdentifier: String, now: Date) async throws -> NativeProfileValidationRequest {
        throw NativeSigningIdentityError.reconciliationRequired
    }

    func privateKeyDER(owner: NativeSigningIdentityOwner, identityID: UUID, now: Date) async throws -> Data {
        throw NativeSigningIdentityError.reconciliationRequired
    }
}

actor NativeSigningIdentityCoordinator<Store: NativeSigningIdentityStorage, Generator: NativeSigningIdentityGenerating> {
    private let store: Store
    private let generator: Generator
    init(store: Store, generator: Generator) { self.store = store; self.generator = generator }

    func localIdentity(owner: NativeSigningIdentityOwner, now: Date) throws -> NativeSigningIdentityInfo? {
        try Task.checkCancellation()
        guard now.timeIntervalSince1970.isFinite else { throw NativeSigningIdentityError.invalidRecord }
        guard let record = try store.read(owner: owner) else { return nil }
        try record.validateShape(owner: owner)
        guard record.createdAt <= now else { throw NativeSigningIdentityError.invalidRecord }
        try Task.checkCancellation()
        return NativeSigningIdentityInfo(ticket: record.ticket,
            certificateSHA256: record.certificateDER.map(NativeSigningIdentityOwner.hash),
            certificateExpiresAt: try record.certificateDER.map(NativeSigningIdentityCrypto.certificateExpiration))
    }

    func prepare(owner: NativeSigningIdentityOwner, now: Date) throws -> NativeSigningIdentityTicket {
        try Task.checkCancellation()
        guard now.timeIntervalSince1970.isFinite else { throw NativeSigningIdentityError.invalidRecord }
        if let existing = try store.read(owner: owner) {
            guard existing.createdAt <= now else { throw NativeSigningIdentityError.invalidRecord }
            try Task.checkCancellation()
            return existing.ticket // retry/restart never silently rotates the key
        }
        let id = UUID()
        let record = try generator.generate(owner: owner, id: id, now: now)
        guard record.id == id, record.phase == .prepared, record.createdAt == now else {
            throw NativeSigningIdentityError.invalidRecord
        }
        try record.validateShape(owner: owner)
        try Task.checkCancellation()
        try store.insert(record, owner: owner)
        // Cancellation after insertion never deletes a durably owned key.
        try Task.checkCancellation()
        return record.ticket
    }

    func ticket(owner: NativeSigningIdentityOwner, identityID: UUID) throws -> NativeSigningIdentityTicket {
        try Task.checkCancellation()
        guard let record = try store.read(owner: owner), record.id == identityID else {
            throw NativeSigningIdentityError.identityChanged
        }
        return record.ticket
    }

    func beginSubmission(owner: NativeSigningIdentityOwner, identityID: UUID) throws -> NativeSigningCSRSubmission {
        try Task.checkCancellation()
        guard var record = try store.read(owner: owner), record.id == identityID else {
            throw NativeSigningIdentityError.identityChanged
        }
        guard record.phase == .prepared else { throw NativeSigningIdentityError.reconciliationRequired }
        record.phase = .submissionUncertain
        try store.replace(record, owner: owner) // MUST precede any possible send
        try Task.checkCancellation()
        return NativeSigningCSRSubmission(identityID: record.id, machineName: record.machineName, csrDER: record.csrDER)
    }

    func recordCertificate(owner: NativeSigningIdentityOwner, identityID: UUID,
                           certificateDER: Data, certificateIdentifier: String, now: Date) throws -> NativeSigningIdentityTicket {
        guard var record = try store.read(owner: owner), record.id == identityID else {
            throw NativeSigningIdentityError.identityChanged
        }
        if record.phase == .certificateRecorded {
            guard record.certificateDER == certificateDER, record.certificateIdentifier == certificateIdentifier else {
                throw NativeSigningIdentityError.identityChanged
            }
            return record.ticket
        }
        guard record.phase == .submissionUncertain else { throw NativeSigningIdentityError.reconciliationRequired }
        try NativeSigningIdentityCrypto.validateCertificate(certificateDER, record: record, now: now)
        record.phase = .certificateRecorded
        record.certificateDER = certificateDER
        record.certificateIdentifier = certificateIdentifier
        try record.validateShape(owner: owner)
        try store.replace(record, owner: owner)
        return record.ticket
    }

    func reconcileUncertain(owner: NativeSigningIdentityOwner, identityID: UUID,
                            certificates: [NativeSigningCertificateObservation], now: Date) throws -> NativeSigningIdentityTicket {
        try Task.checkCancellation()
        guard let record = try store.read(owner: owner), record.id == identityID else {
            throw NativeSigningIdentityError.identityChanged
        }
        guard record.phase == .submissionUncertain else { throw NativeSigningIdentityError.reconciliationRequired }
        guard certificates.count <= 1000, Set(certificates.map(\.identifier)).count == certificates.count else {
            throw NativeSigningIdentityError.certificateRejected
        }
        let matching = try certificates.filter {
            try NativeSigningIdentityCrypto.matchesPublicKey($0.certificateDER, record: record)
        }
        // Zero can mean eventual consistency; multiple can mean duplicate issue.
        // Neither authorizes another submit, arbitrary adoption, or revocation.
        guard matching.count == 1, let certificate = matching.first else {
            throw NativeSigningIdentityError.reconciliationRequired
        }
        try Task.checkCancellation()
        return try recordCertificate(owner: owner, identityID: identityID, certificateDER: certificate.certificateDER,
                                     certificateIdentifier: certificate.identifier, now: now)
    }

    /// Read-only projection from the durable owned identity. No arbitrary
    /// certificate input, private-key export, key generation or portal mutation.
    func profileValidationRequest(owner: NativeSigningIdentityOwner, identityID: UUID, bundleIdentifier: String,
                                  deviceIdentifier: String, now: Date) async throws -> NativeProfileValidationRequest {
        (try await ownedProfileIdentity(owner: owner, identityID: identityID, bundleIdentifier: bundleIdentifier,
                                        deviceIdentifier: deviceIdentifier, now: now)).validation
    }

    func ownedSigningCertificate(owner: NativeSigningIdentityOwner, identityID: UUID, now: Date) async throws -> NativeOwnedSigningCertificate {
        try Task.checkCancellation()
        guard now.timeIntervalSince1970.isFinite else { throw NativeSigningIdentityError.invalidRecord }
        guard let record = try store.read(owner: owner), record.id == identityID else { throw NativeSigningIdentityError.identityChanged }
        guard record.phase == .certificateRecorded, let certificate = record.certificateDER,
              let identifier = record.certificateIdentifier else { throw NativeSigningIdentityError.reconciliationRequired }
        try record.validateShape(owner: owner)
        guard record.createdAt <= now else { throw NativeSigningIdentityError.invalidRecord }
        try NativeSigningIdentityCrypto.validateMaterial(record)
        try NativeSigningIdentityCrypto.validateCertificate(certificate, record: record, now: now)
        try Task.checkCancellation()
        return NativeOwnedSigningCertificate(identityID: record.id, certificateIdentifier: identifier, certificateDER: certificate)
    }

    func ownedProfileIdentity(owner: NativeSigningIdentityOwner, identityID: UUID, bundleIdentifier: String,
                              deviceIdentifier: String, now: Date) async throws -> NativeOwnedProfileIdentity {
        let owned = try await ownedSigningCertificate(owner: owner, identityID: identityID, now: now)
        let validation = try NativeProfileValidationRequest(teamIdentifier: owner.teamIdentifier, bundleIdentifier: bundleIdentifier,
                                                            deviceIdentifier: deviceIdentifier, certificateDER: owned.certificateDER)
        return NativeOwnedProfileIdentity(identityID: owned.identityID, certificateIdentifier: owned.certificateIdentifier, validation: validation)
    }

    func discardPrepared(owner: NativeSigningIdentityOwner, identityID: UUID) throws {
        try Task.checkCancellation()
        guard let record = try store.read(owner: owner), record.id == identityID else {
            throw NativeSigningIdentityError.identityChanged
        }
        guard record.phase == .prepared else { throw NativeSigningIdentityError.cannotDiscardSubmittedIdentity }
        try Task.checkCancellation()
        try store.deletePrepared(record, owner: owner)
    }

    func privateKeyDER(owner: NativeSigningIdentityOwner, identityID: UUID, now: Date) async throws -> Data {
        try Task.checkCancellation()
        guard now.timeIntervalSince1970.isFinite else { throw NativeSigningIdentityError.invalidRecord }
        guard let record = try store.read(owner: owner), record.id == identityID else { throw NativeSigningIdentityError.identityChanged }
        guard record.phase == .prepared || record.phase == .certificateRecorded else { throw NativeSigningIdentityError.reconciliationRequired }
        try record.validateShape(owner: owner)
        guard record.createdAt <= now else { throw NativeSigningIdentityError.invalidRecord }
        try NativeSigningIdentityCrypto.validateMaterial(record)
        try Task.checkCancellation()
        return record.privateKeyDER
    }
}

extension NativeSigningIdentityCoordinator: NativeSigningIdentityManaging {}
