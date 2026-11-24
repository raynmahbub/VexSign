import Foundation

/// Display-only account state. No backend, session bytes, key, approval token or
/// third-party SDK type crosses this boundary.
enum AppleAccountMembership: Equatable, Sendable {
    case free, paidVerified, developerProgramUnverified
}
struct AppleAccountTeam: Equatable, Sendable {
    let identifier: String
    let membership: AppleAccountMembership
}
struct AppleAccountContext: Equatable, Sendable {
    let id: UUID
    let team: AppleAccountTeam
    let expiresAt: Date?
}
enum AppleAccountPhase: Equatable, Sendable {
    case signedOut
    case authenticating(UUID)
    case awaitingTwoFactor(UUID)
    case awaitingTeamSelection(UUID, [AppleAccountTeam], expiresAt: Date?)
    case signedIn(AppleAccountContext)
    case expired(expiresAt: Date?)
}
struct AppleAccountSnapshot: Equatable, Sendable {
    let phase: AppleAccountPhase
    let cleanupRequired: Bool
}
struct AppleAccountRenewalCandidate: Identifiable, Equatable, Sendable {
    let id: UUID
    let bundleIdentifier: String
    let expiresAt: Date
}
struct AppleAccountState: Equatable, Sendable {
    var selectedSlot = 1
    var snapshot: AppleAccountSnapshot?
    var isBackendReady = false
    var lastError: String?
    var freeAccountAppCount = 0
    var freeAccountInventoryAvailable = false
    var renewalCandidates: [AppleAccountRenewalCandidate] = []
}
struct AppleAccountOperation: Identifiable, Equatable, Sendable { let id: UUID }
struct AppleAccountChallenge: Identifiable, Equatable, Sendable {
    let operationID: UUID
    let id: UUID
    let isRetry: Bool
}
struct AppleAccountIdentity: Identifiable, Equatable, Sendable {
    let id: UUID
    let teamIdentifier: String
    var identityID: UUID { id }
    var displayName: String { "Identity \(id.uuidString.prefix(8))" }
}
struct AppleAccountCertificateCheck: Equatable, Sendable {
    let checkedAt: Date
    // Metadata about an explicit successful check, not a reusable signing permit.
}
struct AppleAccountProvisioningRequest: Sendable {
    let contextID: UUID
    let app: LibraryAppReference
    let deviceIdentifier: String
    var requireLaterProfile = false
    var approveRegeneration = false
}
struct AppleAccountProvisioningApproval: Equatable, Sendable {
    let certificate: Bool
    let registration: Bool
    let profile: Bool
    var isComplete: Bool { certificate && registration && profile }
}
struct AppleAccountProvisioningProgress: Equatable, Sendable {
    enum Stage: Equatable, Sendable {
        case preflight, identity, certificateApproval, registration, appRegistration, profile, completed
    }
    let stage: Stage
    let fraction: Double
}
/// This is a receipt owned by the adapter, not an authority to export an arbitrary
/// profile or key. The adapter re-resolves it against the current account and app.
struct AppleAccountProvisioningReceipt: Identifiable, Equatable, Sendable {
    let id: UUID
    let profileUUID: UUID
    let expiresAt: Date
}

/// An exact, process-local transition into the ordinary signing review. It is
/// not a signing grant, installed-state proof, a private key or an account token.
/// No "newest certificate"/stored-index fallback is permitted for this transition.
struct AppleAccountSigningHandoff: Equatable, Sendable {
    let app: LibraryAppReference
    let bundleIdentifier: String
    let certificateUUID: String
    let profileUUID: UUID
    let expiresAt: Date

    func matches(_ candidate: AppInfoPresentable) -> Bool {
        candidate.uuid == app.uuid && candidate.recordID == app.recordID
            && candidate.isSigned == app.isSigned && candidate.identifier == bundleIdentifier
    }

    func certificate(in inventory: [CertificateRecord], now: Date = Date()) -> CertificateRecord? {
        guard now.timeIntervalSince1970.isFinite, expiresAt.timeIntervalSince1970.isFinite,
              expiresAt > now, UUID(uuidString: certificateUUID) != nil else { return nil }
        let matches = inventory.filter { $0.uuid == certificateUUID }
        guard matches.count == 1, let candidate = matches.first, !candidate.revoked,
              candidate.profile.flatMap({ UUID(uuidString: $0.UUID) }) == profileUUID,
              candidate.profile?.ExpirationDate == expiresAt,
              candidate.expiration.map({ $0 > now }) == true else { return nil }
        return candidate
    }
}

enum AppleAccountWorkspaceError: Error, Equatable {
    case approvalRequired, missingReceipt, noActiveContext, incompatibleRenewalSource, expiryNotAdvanced
}

@MainActor
protocol AppleAccountWorkspaceProviding: AnyObject {
    func state() -> AppleAccountState
    func changes() -> AsyncStream<AppleAccountState>
    func selectSlot(_ slot: Int) async throws
    func revalidate() async throws -> AppleAccountOperation
    func synchronizeProvider() async
    func refreshSnapshot() async
    func refreshRenewalCandidates() async
    func authenticate(appleID: String, password: String, xcodeVersion: String) async throws -> AppleAccountOperation
    func challenges(operationID: UUID) -> AsyncStream<AppleAccountChallenge>
    func submitTwoFactorCode(_ code: String, operationID: UUID, challengeID: UUID) async throws -> Bool
    func cancelAuthentication(operationID: UUID) async
    func selectTeam(identifier: String, operationID: UUID) async throws
    func signOut() async throws
    func listSigningIdentities() async -> [AppleAccountIdentity]
    func checkCertificate(contextID: UUID, identityID: UUID) async throws -> AppleAccountCertificateCheck
    func provision(_ request: AppleAccountProvisioningRequest,
                   progress: @escaping @MainActor (AppleAccountProvisioningProgress) -> Void) async throws -> AppleAccountProvisioningReceipt
    func importCertificate(receiptID: UUID) async throws -> AppleAccountSigningHandoff
}
