// MARK: - NativeSigningManager
/// Bridges the NativeSigning module's NativeAccountBackend with VexSign's
/// main app workflows (UnifiedTaskCenter, OptionsManager, SigningProfileStore, etc.).
///
/// Experimental authentication, owner-bound local inventory and profile-only
/// provisioning UI adapter. Mutations require separate explicit approvals; the
/// default CMS gate is closed. Native-owned signing, installation and scoped
/// unattended renewal are not connected to the existing signing pipeline yet.

import Foundation
import Combine
import OSLog
import NativeSigning
// `TwoFactorResponse` is SideSign's; NativeSigning's backend takes it as an argument, so this
// file has to name a type from that module rather than only passing values through.
import SideSign
import NimbleExtensions

@MainActor
final class NativeSigningManager: ObservableObject {
    static let shared = NativeSigningManager()

    // MARK: - Published State

    @Published private(set) var backend: NativeAccountBackend?
    @Published private(set) var snapshot: NativeAccountSnapshot?
    @Published private(set) var isBackendReady = false
    @Published private(set) var lastError: String?
    @Published private(set) var providerDescriptor: AnisetteProviderDescriptor?
    @Published private(set) var freeAccountAppCount: Int = 0
    @Published private(set) var freeAccountInventoryAvailable = false
    @Published private(set) var renewalCandidates: [FreeAccountProfile] = []

    // MARK: - Private State

    private var eventTask: Task<Void, Never>?
    private var providerUpdate: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.vexsign", category: "NativeSigningManager")

    private init() {
        // Initialize from saved provider configuration
        if let descriptor = AnisetteProviderFactory.shared.currentDescriptor {
            self.providerDescriptor = descriptor
        }
        // Start periodic app count refresh
        startAppCountRefresh()
    }

    private func startAppCountRefresh() {
        Task { @MainActor in
            while !Task.isCancelled {
                await refreshFreeAccountAppCount()
                try? await Task.sleep(nanoseconds: 60_000_000_000) // try? ok: cancellation is checked in loop condition
            }
        }
    }

    private func refreshFreeAccountAppCount() async {
        let profiles = await fetchActiveFreeAccountProfiles()
        freeAccountAppCount = Set(profiles.filter { !$0.isExpired }.map(\.bundleIdentifier)).count
        renewalCandidates = freeAccountInventoryAvailable ? profiles.filter { $0.isExpiringSoon } : []
    }

    // MARK: - Profile Expiry Tracking & Auto-Renewal

    /// Represents a provisioning profile with expiry information.
    struct FreeAccountProfile: Identifiable {
        let id: UUID
        let bundleIdentifier: String
        let profileUUID: UUID
        let expiresAt: Date
        /// Existing signing identity, not a newly generated certificate.
        let certificateID: UUID
        var deviceIdentifier: String? = nil
        var daysUntilExpiry: Int {
            // Round up: a profile with 2 days and 20 hours left is still
            // "3 days" of validity, and truncation would report 2.
            let days = (expiresAt.timeIntervalSinceNow / 86400).rounded(.up)
            guard days.isFinite else { return 0 }
            // Display-only clamp; malformed dates must not trap an Int conversion.
            return Int(max(0, min(36_500, days)))
        }
        var isExpiringSoon: Bool { daysUntilExpiry <= 2 }
        var isExpired: Bool { Date() > expiresAt }
    }

    /// Fetches all active free Apple ID profiles with their expiry dates.
    /// Local authenticated receipts only; this is not Apple's complete account
    /// inventory or a quota check. Legacy hash-only rows require reconciliation.
    func fetchActiveFreeAccountProfiles() async -> [FreeAccountProfile] {
        guard let snapshot, case .signedIn(let context) = snapshot.phase,
              context.team.membership == .free, let backend,
              providerDescriptor == AnisetteProviderFactory.shared.currentDescriptor else {
            freeAccountInventoryAvailable = false
            return []
        }
        do {
            let records = try await backend.listProfiles(contextID: context.id)
            guard self.backend === backend,
                  case .signedIn(let current) = self.snapshot?.phase, current.id == context.id,
                  providerDescriptor == AnisetteProviderFactory.shared.currentDescriptor else { return [] }
            let profiles = records.compactMap { record -> FreeAccountProfile? in
                guard let expires = record.expiresAt, let bundle = record.bundleIdentifier,
                      let device = record.deviceIdentifier, let identity = record.identityID else { return nil }
                return FreeAccountProfile(id: record.profileUUID, bundleIdentifier: bundle,
                    profileUUID: record.profileUUID, expiresAt: expires,
                    certificateID: identity, deviceIdentifier: device)
            }
            freeAccountInventoryAvailable = true
            return profiles
        } catch {
            guard self.backend === backend else { return [] }
            freeAccountInventoryAvailable = false
            lastError = error.localizedDescription
            return []
        }
    }

    /// Background discovery is read-only. No certificate generation, registration
    /// or profile approval may be manufactured by a scheduled task. An explicit,
    /// narrowly scoped renewal grant and re-sign/install input are still required.
    func renewExpiringProfiles() async {
        let profiles = await fetchActiveFreeAccountProfiles()
        renewalCandidates = freeAccountInventoryAvailable ? profiles.filter { $0.isExpiringSoon } : []
    }

    // MARK: - Backend Initialization

    /// Initializes the backend with the current provider configuration.
    /// Serialize changes: close old operations before constructing a backend for
    /// the current descriptor. Construction does not log in or grant anisette consent.
    func synchronizeProvider() async {
        let prior = providerUpdate
        let update = Task { @MainActor [weak self] in
            await prior?.value
            guard let self else { return }
            let desired = AnisetteProviderFactory.shared.currentDescriptor
            if self.backend != nil, self.providerDescriptor == desired { return }
            await self.shutdown()
            guard AnisetteProviderFactory.shared.currentDescriptor == desired else { return }
            if desired != nil { self.initializeBackend() }
        }
        providerUpdate = update
        await update.value
    }

    private func configuredBackend() throws -> NativeAccountBackend {
        guard let backend, isBackendReady,
              providerDescriptor == AnisetteProviderFactory.shared.currentDescriptor else {
            throw NativeSigningError.backendNotReady
        }
        return backend
    }

    /// Call after AnisetteProviderFactory is configured.
    func initializeBackend() {
        guard backend == nil else { return }
        guard let descriptor = AnisetteProviderFactory.shared.currentDescriptor else {
            logger.warning("Cannot initialize backend: no anisette provider configured")
            return
        }
        self.providerDescriptor = descriptor
        do {
            let backend = try NativeAccountBackend(provider: descriptor)
            self.backend = backend
            self.isBackendReady = true
            startEventObservation()
            Task { await refreshSnapshot() }
        } catch {
            logger.error("Failed to initialize NativeAccountBackend: \(error.localizedDescription, privacy: .public)")
            self.lastError = error.localizedDescription
            self.isBackendReady = false
        }
    }

    /// Reconfigures the backend with a new provider descriptor.
    func reconfigure(with descriptor: AnisetteProviderDescriptor) async {
        // The factory is authoritative; never construct a different endpoint
        // than the one the configuration UI currently displays.
        guard AnisetteProviderFactory.shared.currentDescriptor == descriptor else { return }
        await synchronizeProvider()
    }

    private func startEventObservation() {
        eventTask?.cancel()
        eventTask = Task { @MainActor [weak self] in
            guard let self, let backend = self.backend else { return }
            do {
                let events = try await backend.events()
                for await event in events {
                    if Task.isCancelled || self.backend !== backend { break }
                    await self.handleEvent(event)
                }
            } catch {
                self.logger.error("Event stream error: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func handleEvent(_ event: NativeAccountEvent) async {
        switch event {
        case .awaitingTeamSelection(let operationID):
            logger.info("Awaiting team selection for operation \(operationID)")
            await refreshSnapshot()
        case .stateChanged(let operationID):
            logger.info("State changed for operation \(operationID)")
            await refreshSnapshot()
        case .failed(let operationID, let error):
            logger.error("Operation \(operationID) failed: \(error)")
            await refreshSnapshot()
            guard !Task.isCancelled else { return }
            lastError = error.localizedDescription
        case .cancelled(let operationID):
            logger.info("Operation \(operationID) cancelled")
            await refreshSnapshot()
        }
    }

    func refreshSnapshot() async {
        guard let backend = backend else { return }
        do {
            let snapshot = try await backend.snapshot()
            guard self.backend === backend, !Task.isCancelled else { return }
            self.snapshot = snapshot
            if case .signedIn = snapshot.phase {} else {
                freeAccountAppCount = 0
                freeAccountInventoryAvailable = false
                renewalCandidates = []
            }
        } catch {
            logger.error("Failed to get snapshot: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Authentication Flow

    /// Starts Apple ID authentication with password.
    /// Returns an operation that emits 2FA challenges if required.
    func authenticate(appleID: String, password: String, xcodeVersion: String) async throws -> NativeAccountOperation {
        let backend = try configuredBackend()

        // Record explicit anisette consent (required before any provider request)
        let consent = try await backend.recordExplicitAnisetteConsent()

        let operation = try await backend.authenticate(
            appleID: appleID,
            password: password,
            xcodeVersion: xcodeVersion,
            consent: consent
        )
        await refreshSnapshot()
        return operation
    }

    /// Submits a 2FA response for a pending challenge.
    func submitTwoFactor(_ response: TwoFactorResponse, operationID: UUID, challengeID: UUID) async throws -> Bool {
        let backend = try configuredBackend()
        let result = try await backend.submitTwoFactor(response, operation: operationID, challengeID: challengeID)
        await refreshSnapshot()
        return result
    }

    /// Cancels an in-flight authentication operation.
    func cancelAuthentication(operationID: UUID) async {
        guard let backend = backend else { return }
        _ = await backend.cancelAuthentication(operation: operationID)
        await refreshSnapshot()
    }

    /// Selects a team after authentication enumerates available teams.
    func selectTeam(identifier: String, operationID: UUID) async throws {
        let backend = try configuredBackend()
        _ = try await backend.selectTeam(identifier: identifier, operation: operationID)
        await refreshSnapshot()
    }

    /// Signs out the current Apple ID (removes session, keeps identities).
    func signOut() async throws {
        let backend = try configuredBackend()
        try await backend.signOut()
        await refreshSnapshot()
    }

    // MARK: - Provisioning Flow

    /// Gets a read-only provisioning preflight plan for a free account context.
    /// This does NOT mutate anything — it only reads Apple's inventory.
    func provisioningPreflight(contextID: UUID, request: NativeAccountProvisioningRequest) async throws -> NativeAccountProvisioningPlan {
        let backend = try configuredBackend()
        let consent = try await backend.recordExplicitAnisetteConsent()
        return try await backend.provisioningPreflight(contextID: contextID, request: request, consent: consent)
    }

    /// Prepares (creates or recovers) the device-only signing identity (key + CSR).
    func prepareSigningIdentity(contextID: UUID) async throws -> NativeSigningIdentityTicket {
        let backend = try configuredBackend()
        return try await backend.prepareSigningIdentity(contextID: contextID)
    }

    /// Fail before quota-affecting work when profile CMS promotion is unavailable.
    func requireProfileOperations() async throws {
        let backend = try configuredBackend()
        guard await backend.profileOperationsAvailable() else {
            throw NativeSigningError.provisioningFailed(.localized("Native profile creation is gated pending CMS validation and device acceptance. No certificate or registration was requested."))
        }
        guard self.backend === backend else { throw CancellationError() }
    }

    /// Records explicit user approval for certificate creation (consumes Apple quota).
    func recordCertificateCreationApproval(contextID: UUID, identityID: UUID) async throws -> NativeCertificateCreationApproval {
        let backend = try configuredBackend()
        return try await backend.recordExplicitCertificateCreationApproval(contextID: contextID, identityID: identityID)
    }

    /// Creates a development signing certificate using the saved CSR.
    func createDevelopmentCertificate(contextID: UUID, identityID: UUID, approval: NativeCertificateCreationApproval) async throws -> NativeSigningIdentityTicket {
        let backend = try configuredBackend()
        let consent = try await backend.recordExplicitAnisetteConsent()
        return try await backend.createDevelopmentSigningCertificate(contextID: contextID, identityID: identityID, approval: approval, consent: consent)
    }

    /// Reconciles an uncertain certificate submission (reads Apple inventory).
    func reconcileCertificate(contextID: UUID, identityID: UUID) async throws -> NativeSigningIdentityTicket {
        let backend = try configuredBackend()
        let consent = try await backend.recordExplicitAnisetteConsent()
        return try await backend.reconcileUncertainSigningCertificate(contextID: contextID, identityID: identityID, consent: consent)
    }

    /// Records explicit approval for device/App ID registration.
    func recordRegistrationApproval(contextID: UUID, subject: NativeRegistrationSubject) async throws -> NativeAccountRegistrationApproval {
        let backend = try configuredBackend()
        return try await backend.recordExplicitRegistrationApproval(contextID: contextID, subject: subject)
    }

    /// Registers a device or App ID with Apple.
    func registerResource(contextID: UUID, subject: NativeRegistrationSubject, approval: NativeAccountRegistrationApproval) async throws -> NativeRegistrationResult {
        let backend = try configuredBackend()
        let consent = try await backend.recordExplicitAnisetteConsent()
        return try await backend.registerAccountResource(contextID: contextID, subject: subject, approval: approval, consent: consent)
    }

    /// Records explicit approval for provisioning profile creation.
    func recordProfileCreationApproval(contextID: UUID, target: NativeAccountProfileTarget) async throws -> NativeAccountProfileApproval {
        let backend = try configuredBackend()
        return try await backend.recordExplicitProfileCreationApproval(contextID: contextID, target: target)
    }

    /// Creates a provisioning profile for the given target.
    func createProvisioningProfile(contextID: UUID, target: NativeAccountProfileTarget, approval: NativeAccountProfileApproval) async throws -> NativeAccountProfileResult {
        let backend = try configuredBackend()
        let consent = try await backend.recordExplicitAnisetteConsent()
        return try await backend.createAccountProvisioningProfile(contextID: contextID, target: target, approval: approval, consent: consent)
    }

    // MARK: - Certificate Status

    /// Records explicit consent for certificate status check (OCSP/CRL).
    func recordCertificateStatusConsent(contextID: UUID, identityID: UUID) async throws -> NativeCertificateStatusConsent {
        let backend = try configuredBackend()
        return try await backend.recordExplicitCertificateStatusConsent(contextID: contextID, identityID: identityID)
    }

    /// Evaluates the signing certificate's revocation status.
    func evaluateCertificateStatus(contextID: UUID, identityID: UUID, consent: NativeCertificateStatusConsent?) async throws -> NativeAccountCertificateStatus {
        let backend = try configuredBackend()
        return try await backend.evaluateSigningCertificateStatus(contextID: contextID, identityID: identityID, consent: consent)
    }

    // MARK: - Cleanup

    /// Shuts down the backend (cancels work, closes observation).
    func shutdown() async {
        eventTask?.cancel()
        eventTask = nil
        let previousBackend = backend
        backend = nil
        isBackendReady = false
        providerDescriptor = nil
        snapshot = nil
        freeAccountAppCount = 0
        freeAccountInventoryAvailable = false
        renewalCandidates = []
        lastError = nil
        await previousBackend?.shutdown()
    }

    // MARK: - Identity Management

    /// Represents a signing identity with certificate information.
    struct SigningIdentity: Identifiable {
        let id: UUID
        let identityID: UUID
        let teamIdentifier: String
        let phase: NativeSigningIdentityPhase
        let publicKeyHash: String
        let csrHash: String?
        let certificateHash: String?
        let certificateExpiresAt: Date?
        var displayName: String {
            "Identity \(identityID.uuidString.prefix(8))"
        }
    }

    /// Lists all signing identities for the current context.
    /// Returns an empty array if not signed in or backend not ready.
    func listSigningIdentities() async -> [SigningIdentity] {
        guard let snapshot, case .signedIn(let context) = snapshot.phase,
              let backend, providerDescriptor == AnisetteProviderFactory.shared.currentDescriptor else { return [] }
        do {
            let records = try await backend.listSigningIdentities(contextID: context.id)
            guard self.backend === backend, case .signedIn(let current) = self.snapshot?.phase,
                  current.id == context.id, providerDescriptor == AnisetteProviderFactory.shared.currentDescriptor else { return [] }
            return records.map { record in
                let ticket = record.ticket
                return SigningIdentity(id: ticket.id, identityID: ticket.id, teamIdentifier: ticket.teamIdentifier,
                    phase: ticket.phase, publicKeyHash: ticket.publicKeySHA256, csrHash: ticket.csrSHA256,
                    certificateHash: record.certificateSHA256, certificateExpiresAt: record.certificateExpiresAt)
            }
        } catch {
            if self.backend === backend { lastError = error.localizedDescription }
            return []
        }
    }

    /// Gets detailed information about a specific identity.
    func getIdentityDetails(identityID: UUID) async -> SigningIdentity? {
        let identities = await listSigningIdentities()
        return identities.first { $0.identityID == identityID }
    }

    // MARK: - Error Mapping

    /// Maps an error to a user-friendly SigningError with recovery guidance.
    func mapError(_ error: Error, context: SigningContext = .general) -> SigningError {
        return SigningErrorMapper.map(error, context: context)
    }
}

// MARK: - NativeSigningError
enum NativeSigningError: LocalizedError {
    case backendNotReady
    case providerNotConfigured
    case noActiveContext
    case noSelectedTeam
    case provisioningFailed(String)
    case signingFailed(String)
    case installationFailed(String)

    var errorDescription: String? {
        switch self {
        case .backendNotReady: return "Native signing backend is not initialized"
        case .providerNotConfigured: return "Anisette provider not configured"
        case .noActiveContext: return "No active signing context (sign in first)"
        case .noSelectedTeam: return "No team selected"
        case .provisioningFailed(let msg): return "Provisioning failed: \(msg)"
        case .signingFailed(let msg): return "Signing failed: \(msg)"
        case .installationFailed(let msg): return "Installation failed: \(msg)"
        }
    }
}

// MARK: - AnisetteProviderDescriptor Extension
extension AnisetteProviderDescriptor {
    /// Creates a descriptor for the default HTTPS header-JSON provider.
    /// The endpoint must be configured by the user or app.
    static func defaultHTTPS(endpoint: URL, identity: String, policyRevision: Int) -> AnisetteProviderDescriptor {
        try! AnisetteProviderDescriptor(
            identifier: identity,
            displayName: "Custom Anisette Server",
            policyRevision: String(policyRevision),
            endpoint: endpoint
        )
    }
}// CI trigger
// CI trigger
// CI trigger Wed Nov  4 17:16:38 UTC 2026
