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

enum AppleAccountWorkspaceError: Error, Equatable {
    case approvalRequired, missingReceipt, noActiveContext
}

@MainActor
protocol AppleAccountWorkspaceProviding: AnyObject {
    func state() -> AppleAccountState
    func changes() -> AsyncStream<AppleAccountState>
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
    func importCertificate(receiptID: UUID) async throws
}
