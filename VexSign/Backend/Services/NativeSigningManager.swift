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
        // Count apps signed with free Apple ID
        // This would query the NativeAccountBackend for identities/profiles
        // For now, we'll scan signed apps and check their signing method
        let apps = Storage.shared.getAllApps().filter { $0.isSigned }
        // TODO: Actually check which apps use free Apple ID profiles
        // For now, return 0 as placeholder
        // In a real implementation, this would query the backend for active profiles
        // freeAccountAppCount = await backend?.countActiveFreeAccountProfiles() ?? 0
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
            max(0, Int(expiresAt.timeIntervalSinceNow / 86400))
        }
        var isExpiringSoon: Bool { daysUntilExpiry <= 2 }
        var isExpired: Bool { Date() > expiresAt }
    }

    /// Fetches all active free Apple ID profiles with their expiry dates.
    /// Returns an empty array if not signed in or backend not ready.
    func fetchActiveFreeAccountProfiles() async -> [FreeAccountProfile] {
        guard let backend = backend,
              let snapshot = snapshot,
              case .signedIn(let context) = snapshot.phase,
              managerIsFreeAccount(context) else {
            return []
        }

        do {
            // Get the context ID for this signed-in session
            let contextID = context.id

            // TODO: In a real implementation, query the backend for all profiles
            // associated with this context. The NativeAccountBackend would need
            // a method to list profiles with their expiry dates.
            // For now, return empty array as placeholder.
            // This would require adding a method like:
            // backend.listProfiles(contextID: contextID) -> [ProfileInfo]

            return []
        } catch {
            logger.error("Failed to fetch free account profiles: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Checks if the current context is a free Apple ID account (not paid).
    private func managerIsFreeAccount(_ context: NativeAccountContext) -> Bool {
        context.team.membership == .free || context.team.membership == .developerProgramUnverified
    }

    /// Checks for expiring profiles and triggers renewal for each.
    /// Called by BackgroundAutomation during scheduled maintenance.
    func renewExpiringProfiles() async {
        guard let backend = backend,
              let snapshot = snapshot,
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
            title: .localized("Renewing profile: %@", bundleIdentifier),
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
            let consent = try await backend.recordExplicitAnisetteConsent()
            let plan = try await backend.provisioningPreflight(contextID: contextID, request: request, consent: consent)

            // 2. Prepare signing identity (key + CSR)
            let identityTicket = try await backend.prepareSigningIdentity(contextID: contextID)

            // 3. Certificate creation approval
            let certApproval = try await backend.recordCertificateCreationApproval(contextID: contextID, identityID: identityTicket.identityID)

            // 4. Create certificate
            let consent2 = try await backend.recordExplicitAnisetteConsent()
            _ = try await backend.createDevelopmentSigningCertificate(
                contextID: contextID,
                identityID: identityTicket.identityID,
                approval: certApproval,
                consent: consent2
            )

            // 5. Device registration
            let subject = try NativeRegistrationSubject(kind: .device, value: deviceIdentifier)
            let regApproval = try await backend.recordRegistrationApproval(contextID: contextID, subject: subject)
            let consent3 = try await backend.recordExplicitAnisetteConsent()
            _ = try await backend.registerAccountResource(contextID: contextID, subject: subject, approval: regApproval, consent: consent3)

            // 6. App ID registration
            let appIDSubject = try NativeRegistrationSubject(kind: .appID, value: bundleIdentifier)
            let appIDApproval = try await backend.recordRegistrationApproval(contextID: contextID, subject: appIDSubject)
            let consent4 = try await backend.recordExplicitAnisetteConsent()
            _ = try await backend.registerAccountResource(contextID: contextID, subject: appIDSubject, approval: appIDApproval, consent: consent4)

            // 7. Profile creation
            let target = try NativeAccountProfileTarget(
                identityID: identityTicket.identityID,
                bundleIdentifier: bundleIdentifier,
                deviceIdentifier: deviceIdentifier.uppercased(),
                registeredAppID: plan.existingAppIdentifiers.first ?? bundleIdentifier,
                registeredDeviceID: "auto"
            )
            let profileApproval = try await backend.recordExplicitProfileCreationApproval(contextID: contextID, target: target)
            let consent5 = try await backend.recordExplicitAnisetteConsent()
            let profileResult = try await backend.createAccountProvisioningProfile(
                contextID: contextID,
                target: target,
                approval: profileApproval,
                consent: consent5
            )

            // 8. Re-sign and queue the app for installation
            await reSignAppWithNewProfile(bundleIdentifier: bundleIdentifier, profileResult: profileResult)

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

        // Try to get from Storage if available
        if let app = Storage.shared.getAllApps().first(where: { $0.identifier == bundleIdentifier && $0.isSigned }),
           let uuid = app.uuid {
            // This is the app's UUID, not the device UDID
            // We need the actual device UDID
        }

        // For now, throw an error indicating manual input needed
        throw NativeSigningError.provisioningFailed("Device UDID required for renewal. Please run provisioning manually.")
    }

    /// Re-signs an app with the newly created profile and queues for installation.
    /// This integrates with the existing Zsign signing pipeline and InstallQueue.
    private func reSignAppWithNewProfile(bundleIdentifier: String, profileResult: NativeAccountProfileResult) async {
        guard let backend = backend,
              let snapshot = snapshot,
              case .signedIn(let context) = snapshot.phase else {
            logger.error("Cannot re-sign: no active signing context")
            return
        }

        do {
            // 1. Find the app in the library
            let apps = Storage.shared.getAllApps()
            guard let app = apps.first(where: { $0.identifier == bundleIdentifier && $0.isSigned }) else {
                logger.error("App not found in library: \(bundleIdentifier)")
                return
            }

            // 2. Get the identity and certificate for this context
            // We need to find the identity that was used to create this profile
            let identities = try await backend.listProfiles(contextID: context.id)
            guard let identity = identities.first else {
                logger.error("No signing identity found for re-signing")
                return
            }

            // 3. Export certificate and private key as .p12
            let keyExportConsent = try await backend.recordExplicitKeyExportConsent(
                contextID: context.id,
                identityID: identity.identityID
            )
            let (p12Data, p12Password) = try await exportSigningIdentityAsP12(
                contextID: context.id,
                identityID: identity.identityID,
                password: generateRandomPassword(),
                consent: keyExportConsent
            )

            // 4. Download the provisioning profile as .mobileprovision
            let anisetteConsent = try await backend.recordExplicitAnisetteConsent()
            let profileData = try await downloadProvisioningProfile(
                contextID: context.id,
                profileUUID: profileResult.profileUUID,
                consent: anisetteConsent
            )

            // 5. Create Zsign request and sign
            let signedIPAURL = try await signWithZsign(
                app: app,
                p12Data: p12Data,
                p12Password: p12Password,
                profileData: profileData
            )

            // 6. Update the app record with the new signed IPA and enqueue for installation
            await updateAppAndEnqueueForInstallation(app: app, signedIPAURL: signedIPAURL)

            logger.info("Successfully re-signed \(bundleIdentifier) with new profile \(profileResult.profileUUID)")

        } catch {
            logger.error("Failed to re-sign \(bundleIdentifier): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Generates a random password for the .p12 file.
    private func generateRandomPassword() -> String {
        let characters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*"
        return String((0..<32).map { _ in characters.randomElement()! })
    }

    /// Exports the signing identity (private key + certificate) as a .p12 file.
    private func exportSigningIdentityAsP12(
        contextID: UUID,
        identityID: UUID,
        password: String,
        consent: NativeKeyExportConsent
    ) async throws -> (Data, String) {
        guard let backend = backend else { throw NativeSigningError.backendNotReady }
        let p12Data = try await backend.exportSigningIdentity(
            contextID: contextID,
            identityID: identityID,
            password: password,
            consent: consent
        )
        return (p12Data, password)
    }

    /// Downloads the provisioning profile from Apple as a .mobileprovision file.
    private func downloadProvisioningProfile(
        contextID: UUID,
        profileUUID: UUID,
        consent: AnisetteConsentToken
    ) async throws -> Data {
        guard let backend = backend else { throw NativeSigningError.backendNotReady }
        return try await backend.downloadProvisioningProfile(
            contextID: contextID,
            profileUUID: profileUUID,
            consent: consent
        )
    }

    /// Signs an app using Zsign with the provided certificate and profile.
    private func signWithZsign(
        app: AppInfoPresentable,
        p12Data: Data,
        p12Password: String,
        profileData: Data
    ) async throws -> URL {
        // Create temporary files for Zsign
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("VexSignReSign_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let appPath = tempDir.appendingPathComponent("app.ipa")
        let p12Path = tempDir.appendingPathComponent("cert.p12")
        let profilePath = tempDir.appendingPathComponent("profile.mobileprovision")
        let outputPath = tempDir.appendingPathComponent("signed.ipa")

        // Copy the original IPA
        let originalIPAURL = app.localURL
        try FileManager.default.copyItem(at: originalIPAURL, to: appPath)

        // Write certificate and profile
        try p12Data.write(to: p12Path)
        try profileData.write(to: profilePath)

        // Create Zsign request
        var request = ZsignEngine.Request(appPath: appPath.path)
        request.p12Path = p12Path.path
        request.p12Password = p12Password
        request.provisionPath = profilePath.path
        request.removeProvisioning = false // Keep the new profile

        // Run Zsign
        let outcome = ZsignEngine.sign(request)
        if let errorMessage = outcome.errorMessage {
            throw NativeSigningError.signingFailed("Zsign failed: \(errorMessage)")
        }
        if !outcome.succeeded {
            throw NativeSigningError.signingFailed("Zsign signing failed")
        }

        // Zsign typically modifies the app in place
        return appPath
    }

    /// Updates the app record with the new signed IPA and enqueues for installation.
    private func updateAppAndEnqueueForInstallation(app: AppInfoPresentable, signedIPAURL: URL) async {
        // Move the signed IPA to the app's directory
        let appDir = Storage.shared.getAppDirectory(for: app) ?? Storage.shared.getImportedAppDirectory(for: app)
        guard let appDir = appDir else {
            logger.error("Could not find app directory for \(app.identifier)")
            return
        }

        let destinationURL = appDir.appendingPathComponent("\(app.fileName).ipa")
        do {
            // Remove old IPA if exists
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            // Move new signed IPA
            try FileManager.default.moveItem(at: signedIPAURL, to: destinationURL)

            // Update the app record in storage (mark as signed with new profile)
            // The Signed app record will be updated when the installation completes
            // For now, enqueue the app for installation using the existing pipeline
            await MainActor.run {
                InstallQueue.shared.enqueue(app, exporting: false)
            }

            logger.info("Enqueued \(app.identifier) for installation with new profile")
        } catch {
            logger.error("Failed to update app and enqueue: \(error.localizedDescription, privacy: .public)")
        }
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
        guard let backend = backend,
              let snapshot = snapshot,
              case .signedIn(let context) = snapshot.phase else {
            return []
        }

        // TODO: In a real implementation, this would query the backend for all identities
        // associated with this context. The NativeAccountBackend would need a method like:
        // backend.listIdentities(contextID: context.id) -> [IdentityInfo]

        // For now, return empty array as placeholder
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
