// MARK: - NativeSigningManager
/// Bridges the NativeSigning module's NativeAccountBackend with VexSign's
/// main app workflows (UnifiedTaskCenter, OptionsManager, SigningProfileStore, etc.).
///
/// This manager handles the complete free Apple ID signing flow:
/// 1. Apple ID + password authentication (with 2FA)
/// 2. Team selection (free vs paid)
/// 3. Device/App ID registration
/// 4. Certificate creation
/// 5. Provisioning profile creation
/// 6. Integration with existing Zsign signing pipeline
///
/// All operations are funneled through UnifiedTaskCenter for consistent
/// progress tracking, history, and retry handling.

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

    // MARK: - Private State

    private var eventTask: Task<Void, Never>?
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
        // Scanning the library cannot say which Apple ID signed what, so the count
        // stays at zero until the backend can list free-account profiles.
        // TODO: replace with a NativeAccountBackend query.
        let signedCount = Storage.shared.getAllApps().filter { $0.isSigned }.count
        logger.debug("Signed apps in library: \(signedCount); free-account profile count unavailable")
    }

    // MARK: - Profile Expiry Tracking & Auto-Renewal

    /// Represents a provisioning profile with expiry information.
    struct FreeAccountProfile: Identifiable {
        let id: UUID
        let bundleIdentifier: String
        let profileUUID: UUID
        let expiresAt: Date
        let certificateID: UUID
        var daysUntilExpiry: Int {
            // Round up: a profile with 2 days and 20 hours left is still
            // "3 days" of validity, and truncation would report 2.
            let days = (expiresAt.timeIntervalSinceNow / 86400).rounded(.up)
            return max(0, Int(days))
        }
        var isExpiringSoon: Bool { daysUntilExpiry <= 2 }
        var isExpired: Bool { Date() > expiresAt }
    }

    /// Fetches all active free Apple ID profiles with their expiry dates.
    /// Returns an empty array if not signed in or backend not ready.
    func fetchActiveFreeAccountProfiles() async -> [FreeAccountProfile] {
        guard let snapshot = snapshot,
              case .signedIn(let context) = snapshot.phase,
              managerIsFreeAccount(context) else {
            return []
        }

        // TODO: query the backend for the profiles belonging to this context and
        // their expiry dates. NativeAccountBackend has listProfiles(contextID:),
        // but it returns profile records, not the expiry data renewal needs, so
        // there is nothing to renew yet and the count stays at zero.
        _ = context.id
        return []
    }

    /// Checks if the current context is a free Apple ID account (not paid).
    private func managerIsFreeAccount(_ context: NativeAccountContext) -> Bool {
        context.team.membership == .free || context.team.membership == .developerProgramUnverified
    }

    /// Checks for expiring profiles and triggers renewal for each.
    /// Called by BackgroundAutomation during scheduled maintenance.
    func renewExpiringProfiles() async {
        guard let snapshot = snapshot,
              case .signedIn(let context) = snapshot.phase,
              managerIsFreeAccount(context),
              isBackendReady else {
            return
        }

        let profiles = await fetchActiveFreeAccountProfiles()
        let expiringProfiles = profiles.filter { $0.isExpiringSoon && !$0.isExpired }

        for profile in expiringProfiles {
            await renewProfile(bundleIdentifier: profile.bundleIdentifier, contextID: context.id)
        }
    }

    /// Attempts to renew a specific profile by re-provisioning.
    private func renewProfile(bundleIdentifier: String, contextID: UUID) async {
        logger.info("Attempting to renew profile for \(bundleIdentifier)")

        // Create a unified task for tracking
        let task = UnifiedTaskCenter.shared.begin(
            kind: .update,
            title: .localized("Renewing profile: %@", arguments: bundleIdentifier),
            subtitle: .localized("Free Apple ID profile expiring soon"),
            subjectID: bundleIdentifier
        )

        do {
            // 1. Get device identifier for this app
            // In a real implementation, this would come from the stored profile info
            // For now, we need to get it from somewhere
            let deviceIdentifier = try await getDeviceIdentifierForApp(bundleIdentifier)

            // 2. Run provisioning preflight
            let request = try NativeAccountProvisioningRequest(
                deviceIdentifier: deviceIdentifier,
                bundleIdentifiers: [bundleIdentifier]
            )
            // Steps 2-7 go through this manager's own pass-throughs rather than the
            // backend directly: they guard the optional backend and mint a fresh
            // AnisetteConsentToken per mutating call, which is the only shape the
            // backend accepts.
            let plan = try await provisioningPreflight(contextID: contextID, request: request)

            // 2. Prepare signing identity (key + CSR)
            let identityTicket = try await prepareSigningIdentity(contextID: contextID)

            // 3. Certificate creation approval
            let certApproval = try await recordCertificateCreationApproval(contextID: contextID, identityID: identityTicket.id)

            // 4. Create certificate
            _ = try await createDevelopmentCertificate(
                contextID: contextID,
                identityID: identityTicket.id,
                approval: certApproval
            )

            // 5. Device registration
            let subject = try NativeRegistrationSubject(kind: .device, value: deviceIdentifier)
            let regApproval = try await recordRegistrationApproval(contextID: contextID, subject: subject)
            _ = try await registerResource(contextID: contextID, subject: subject, approval: regApproval)

            // 6. App ID registration
            let appIDSubject = try NativeRegistrationSubject(kind: .appID, value: bundleIdentifier)
            let appIDApproval = try await recordRegistrationApproval(contextID: contextID, subject: appIDSubject)
            _ = try await registerResource(contextID: contextID, subject: appIDSubject, approval: appIDApproval)

            // 7. Profile creation
            let target = try NativeAccountProfileTarget(
                identityID: identityTicket.id,
                bundleIdentifier: bundleIdentifier,
                deviceIdentifier: deviceIdentifier.uppercased(),
                registeredAppID: plan.existingAppIdentifiers.first ?? bundleIdentifier,
                registeredDeviceID: "auto"
            )
            let profileApproval = try await recordProfileCreationApproval(contextID: contextID, target: target)
            let profileResult = try await createProvisioningProfile(contextID: contextID, target: target, approval: profileApproval)

            // 8. The renewed profile is now recorded by the backend. Re-signing stays
            // with the normal signing pipeline (FR.signPackageFile -> SigningService),
            // which owns the live activity, the unified task record and the signing
            // log. A second Zsign path here would bypass all three, and there is no
            // stored original IPA to feed it: import extracts the payload, it does not
            // keep the archive.
            logger.info("Renewed profile \(profileResult.profileUUID.uuidString, privacy: .public) for \(bundleIdentifier); re-sign it from the library")

            await MainActor.run {
                UnifiedTaskCenter.shared.transition(task, to: .completed)
            }

        } catch {
            await MainActor.run {
                UnifiedTaskCenter.shared.transition(task, to: .failed, error: error.localizedDescription)
            }
            logger.error("Failed to renew profile for \(bundleIdentifier): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Gets the device identifier for an app (from stored profile or device pairing).
    private func getDeviceIdentifierForApp(_ bundleIdentifier: String) async throws -> String {
        // In a real implementation, this would query the Keychain or profile storage
        // for the device UDID associated with this app's profile.
        // For now, we'll need to get it from the paired device or user input.

        // The library stores the app's own UUID, which is not the device UDID, so
        // nothing in storage can answer this.
        throw NativeSigningError.provisioningFailed("Device UDID required for renewal. Please run provisioning manually.")
    }

    // MARK: - Backend Initialization

    /// Initializes the backend with the current provider configuration.
    /// Call after AnisetteProviderFactory is configured.
    func initializeBackend() {
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
        await shutdown()
        self.providerDescriptor = descriptor
        initializeBackend()
    }

    private func startEventObservation() {
        eventTask?.cancel()
        eventTask = Task { @MainActor [weak self] in
            guard let self, let backend = self.backend else { return }
            do {
                let events = try await backend.events()
                for await event in events {
                    if Task.isCancelled { break }
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
            await MainActor.run { self.snapshot = snapshot }
        } catch {
            logger.error("Failed to get snapshot: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Authentication Flow

    /// Starts Apple ID authentication with password.
    /// Returns an operation that emits 2FA challenges if required.
    func authenticate(appleID: String, password: String, xcodeVersion: String) async throws -> NativeAccountOperation {
        guard let backend = backend else { throw NativeSigningError.backendNotReady }

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
        guard let backend = backend else { throw NativeSigningError.backendNotReady }
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
        guard let backend = backend else { throw NativeSigningError.backendNotReady }
        _ = try await backend.selectTeam(identifier: identifier, operation: operationID)
        await refreshSnapshot()
    }

    /// Signs out the current Apple ID (removes session, keeps identities).
    func signOut() async throws {
        guard let backend = backend else { throw NativeSigningError.backendNotReady }
        try await backend.signOut()
        await refreshSnapshot()
    }

    // MARK: - Provisioning Flow

    /// Gets a read-only provisioning preflight plan for a free account context.
    /// This does NOT mutate anything — it only reads Apple's inventory.
    func provisioningPreflight(contextID: UUID, request: NativeAccountProvisioningRequest) async throws -> NativeAccountProvisioningPlan {
        guard let backend = backend else { throw NativeSigningError.backendNotReady }
        let consent = try await backend.recordExplicitAnisetteConsent()
        return try await backend.provisioningPreflight(contextID: contextID, request: request, consent: consent)
    }

    /// Prepares (creates or recovers) the device-only signing identity (key + CSR).
    func prepareSigningIdentity(contextID: UUID) async throws -> NativeSigningIdentityTicket {
        guard let backend = backend else { throw NativeSigningError.backendNotReady }
        return try await backend.prepareSigningIdentity(contextID: contextID)
    }

    /// Records explicit user approval for certificate creation (consumes Apple quota).
    func recordCertificateCreationApproval(contextID: UUID, identityID: UUID) async throws -> NativeCertificateCreationApproval {
        guard let backend = backend else { throw NativeSigningError.backendNotReady }
        return try await backend.recordExplicitCertificateCreationApproval(contextID: contextID, identityID: identityID)
    }

    /// Creates a development signing certificate using the saved CSR.
    func createDevelopmentCertificate(contextID: UUID, identityID: UUID, approval: NativeCertificateCreationApproval) async throws -> NativeSigningIdentityTicket {
        guard let backend = backend else { throw NativeSigningError.backendNotReady }
        let consent = try await backend.recordExplicitAnisetteConsent()
        return try await backend.createDevelopmentSigningCertificate(contextID: contextID, identityID: identityID, approval: approval, consent: consent)
    }

    /// Reconciles an uncertain certificate submission (reads Apple inventory).
    func reconcileCertificate(contextID: UUID, identityID: UUID) async throws -> NativeSigningIdentityTicket {
        guard let backend = backend else { throw NativeSigningError.backendNotReady }
        let consent = try await backend.recordExplicitAnisetteConsent()
        return try await backend.reconcileUncertainSigningCertificate(contextID: contextID, identityID: identityID, consent: consent)
    }

    /// Records explicit approval for device/App ID registration.
    func recordRegistrationApproval(contextID: UUID, subject: NativeRegistrationSubject) async throws -> NativeAccountRegistrationApproval {
        guard let backend = backend else { throw NativeSigningError.backendNotReady }
        return try await backend.recordExplicitRegistrationApproval(contextID: contextID, subject: subject)
    }

    /// Registers a device or App ID with Apple.
    func registerResource(contextID: UUID, subject: NativeRegistrationSubject, approval: NativeAccountRegistrationApproval) async throws -> NativeRegistrationResult {
        guard let backend = backend else { throw NativeSigningError.backendNotReady }
        let consent = try await backend.recordExplicitAnisetteConsent()
        return try await backend.registerAccountResource(contextID: contextID, subject: subject, approval: approval, consent: consent)
    }

    /// Records explicit approval for provisioning profile creation.
    func recordProfileCreationApproval(contextID: UUID, target: NativeAccountProfileTarget) async throws -> NativeAccountProfileApproval {
        guard let backend = backend else { throw NativeSigningError.backendNotReady }
        return try await backend.recordExplicitProfileCreationApproval(contextID: contextID, target: target)
    }

    /// Creates a provisioning profile for the given target.
    func createProvisioningProfile(contextID: UUID, target: NativeAccountProfileTarget, approval: NativeAccountProfileApproval) async throws -> NativeAccountProfileResult {
        guard let backend = backend else { throw NativeSigningError.backendNotReady }
        let consent = try await backend.recordExplicitAnisetteConsent()
        return try await backend.createAccountProvisioningProfile(contextID: contextID, target: target, approval: approval, consent: consent)
    }

    // MARK: - Certificate Status

    /// Records explicit consent for certificate status check (OCSP/CRL).
    func recordCertificateStatusConsent(contextID: UUID, identityID: UUID) async throws -> NativeCertificateStatusConsent {
        guard let backend = backend else { throw NativeSigningError.backendNotReady }
        return try await backend.recordExplicitCertificateStatusConsent(contextID: contextID, identityID: identityID)
    }

    /// Evaluates the signing certificate's revocation status.
    func evaluateCertificateStatus(contextID: UUID, identityID: UUID, consent: NativeCertificateStatusConsent?) async throws -> NativeAccountCertificateStatus {
        guard let backend = backend else { throw NativeSigningError.backendNotReady }
        return try await backend.evaluateSigningCertificateStatus(contextID: contextID, identityID: identityID, consent: consent)
    }

    // MARK: - Cleanup

    /// Shuts down the backend (cancels work, closes observation).
    func shutdown() async {
        eventTask?.cancel()
        eventTask = nil
        await backend?.shutdown()
        backend = nil
        isBackendReady = false
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
        guard let snapshot = snapshot,
              case .signedIn = snapshot.phase else {
            return []
        }

        // TODO: list the identities belonging to this context. NativeAccountBackend
        // exposes listProfiles(contextID:), which returns profile records rather than
        // identities, so there is nothing to enumerate yet.
        return []
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
