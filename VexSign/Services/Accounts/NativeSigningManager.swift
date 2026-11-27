/// Bridges the NativeSigning module's NativeAccountBackend with VexSign's
/// main app workflows (UnifiedTaskCenter, OptionsManager, SigningProfileStore, etc.).
///
/// Experimental authentication, owner-bound inventory and receipt-bound
/// certificate-store handoff. Mutations/key export require separate explicit
/// approvals; strict CMS authentication is required. Signing/install remain ordinary
/// user actions. Scoped unattended renewal is not connected.

import Foundation
import Combine
import OSLog
import Security
import NativeSigning
// `TwoFactorResponse` is SideSign's; NativeSigning's backend takes it as an argument, so this
// file has to name a type from that module rather than only passing values through.
import SideSign
import NimbleExtensions

/// App-side preflight after the package has authenticated the CMS. This catches
/// accidental target drift before the single-use private-key grant is consumed;
/// it is not a replacement for the package's Apple trust verification.
struct NativeSigningHandoffPreflight {
    static func validate(
        _ profile: Certificate,
        profileUUID: UUID,
        expiresAt: Date,
        teamIdentifier: String,
        identity: NativeSigningManager.SigningIdentity,
        bundleIdentifier: String,
        deviceIdentifier: String,
        now: Date = Date()
    ) throws {
        let appIdentifier = teamIdentifier + "." + bundleIdentifier
        let entitlements = profile.Entitlements
        let groups = entitlements?["keychain-access-groups"]?.value as? [String]
        guard profile.Version == 1, profile.Platform == ["iOS"],
              UUID(uuidString: profile.UUID) == profileUUID,
              profile.CreationDate <= now, profile.ExpirationDate == expiresAt, expiresAt > now,
              profile.TeamIdentifier == [teamIdentifier], profile.ApplicationIdentifierPrefix == [teamIdentifier],
              identity.teamIdentifier == teamIdentifier, identity.phase == .certificateRecorded,
              profile.ProvisionsAllDevices != true,
              profile.ProvisionedDevices?.contains(where: { $0.uppercased() == deviceIdentifier.uppercased() }) == true,
              profile.DeveloperCertificates?.isEmpty == false,
              entitlements?["application-identifier"]?.value as? String == appIdentifier,
              entitlements?["com.apple.developer.team-identifier"]?.value as? String == teamIdentifier,
              entitlements?["get-task-allow"]?.value as? Bool == true,
              let groups, !groups.isEmpty,
              groups.allSatisfy({ $0 == appIdentifier || $0 == teamIdentifier + ".*" }) else {
            throw NativeSigningError.provisioningFailed(.localized("The authenticated profile does not match the selected team, identity, app, device, or expiry. Nothing was imported."))
        }
    }
}

/// Owns the certificate-handoff transaction after the manager has captured its
/// authenticated account and identity. Operations stay injectable so lifecycle,
/// cancellation and protected-file cleanup can be tested without Apple access.
/// This does not implement signing or replace the ordinary certificate importer.
@MainActor
struct NativeSigningHandoffCoordinator {
    struct Request {
        let profileUUID: UUID
        let expiresAt: Date
        let teamIdentifier: String
        let identity: NativeSigningManager.SigningIdentity
        let bundleIdentifier: String
        let deviceIdentifier: String
    }

    private let taskCenter: UnifiedTaskCenter
    private let temporaryDirectory: URL
    private let generatePassword: () throws -> String
    private let now: () -> Date
    private let authenticateProfile: (Data, Date) throws -> Certificate

    init(
        taskCenter: UnifiedTaskCenter? = nil,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        generatePassword: (() throws -> String)? = nil,
        now: @escaping () -> Date = { Date() },
        authenticateProfile: @escaping (Data, Date) throws -> Certificate = {
            try ProvisioningProfileParser.parse($0, now: $1)
        }
    ) {
        self.taskCenter = taskCenter ?? .shared
        self.temporaryDirectory = temporaryDirectory
        self.generatePassword = generatePassword ?? Self.makePassword
        self.now = now
        self.authenticateProfile = authenticateProfile
    }

    func run<Imported: Sendable>(
        request: Request,
        exportProfile: () async throws -> Data,
        backendIsCurrent: () -> Bool,
        exportIdentity: (String) async throws -> Data,
        importCertificate: (_ p12URL: URL, _ provisionURL: URL, _ password: String, _ name: String) async throws -> Imported
    ) async throws -> Imported {
        let task = taskCenter.begin(kind: .export,
            title: .localized("Import Apple ID Certificate"), subtitle: request.bundleIdentifier,
            phase: .queued, subjectID: request.profileUUID.uuidString)
        let directory = temporaryDirectory
            .appendingPathComponent("native-signing-handoff-" + UUID().uuidString, isDirectory: true)
        do {
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700, .protectionKey: FileProtectionType.complete])
            defer { try? FileManager.default.removeItem(at: directory) } // try? ok: import result is already known; scratch cleanup is best-effort

            taskCenter.transition(task, to: .downloading, progress: 0.15)
            let profileData = try await exportProfile()
            try Task.checkCancellation()
            guard backendIsCurrent() else { throw CancellationError() }
            let provisionURL = directory.appendingPathComponent("native.mobileprovision")
            try Self.write(profileData, to: provisionURL)
            let decoded: Certificate
            do {
                // The production default consumes and authenticates the entire
                // CMS using the transaction's clock. No substring/plist fallback.
                decoded = try authenticateProfile(profileData, now())
            } catch {
                throw NativeSigningError.provisioningFailed(.localized("The authenticated provisioning profile could not be read. Nothing was imported."))
            }
            taskCenter.transition(task, to: .extracting, progress: 0.4)
            try NativeSigningHandoffPreflight.validate(decoded, profileUUID: request.profileUUID,
                expiresAt: request.expiresAt, teamIdentifier: request.teamIdentifier,
                identity: request.identity, bundleIdentifier: request.bundleIdentifier,
                deviceIdentifier: request.deviceIdentifier, now: now())

            taskCenter.transition(task, to: .importing, progress: 0.65)
            let password = try generatePassword()
            let p12Data = try await exportIdentity(password)
            try Task.checkCancellation()
            guard backendIsCurrent() else { throw CancellationError() }
            // Export can suspend across profile expiry. Recheck the frozen
            // authenticated metadata with the current transaction clock before
            // persisting a private-key copy or importing a now-expired pair.
            try NativeSigningHandoffPreflight.validate(decoded, profileUUID: request.profileUUID,
                expiresAt: request.expiresAt, teamIdentifier: request.teamIdentifier,
                identity: request.identity, bundleIdentifier: request.bundleIdentifier,
                deviceIdentifier: request.deviceIdentifier, now: now())
            let p12URL = directory.appendingPathComponent("native.p12")
            try Self.write(p12Data, to: p12URL)
            let name = "Apple ID " + String(request.identity.identityID.uuidString.prefix(8))
            let imported = try await importCertificate(p12URL, provisionURL, password, name)
            taskCenter.transition(task, to: .completed, progress: 1)
            return imported
        } catch {
            if error is CancellationError || Task.isCancelled {
                taskCenter.transition(task, to: .cancelled)
            } else {
                taskCenter.transition(task, to: .failed, error: error.localizedDescription)
            }
            throw error
        }
    }

    private static func write(_ data: Data, to url: URL) throws {
        guard !data.isEmpty, data.count <= 2 * 1024 * 1024 else {
            throw NativeSigningError.signingFailed(.localized("The native certificate export was empty or too large. Nothing was imported."))
        }
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func makePassword() throws -> String {
        var bytes = Data(count: 32)
        let status = bytes.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let address = buffer.baseAddress else { return errSecAllocate }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, address)
        }
        guard status == errSecSuccess else {
            throw NativeSigningError.signingFailed(.localized("A secure password for the certificate export could not be generated. Nothing was imported."))
        }
        return bytes.base64EncodedString()
    }
}

// MARK: - NativeSigningManager

@MainActor
final class NativeSigningManager: ObservableObject {
    static let shared = NativeSigningManager()

    // MARK: - Published State

    @Published private(set) var backend: NativeAccountBackend?
    @Published private(set) var snapshot: NativeAccountSnapshot?
    @Published private(set) var isBackendReady = false
    @Published private(set) var lastError: String?
    @Published private(set) var providerDescriptor: AnisetteProviderDescriptor?
    private struct Inventory {
        let scope: AccountInventoryScope
        let count: Int
        let candidates: [FreeAccountProfile]
    }
    @Published private var inventory: Inventory?
    private var inventoryReads = AccountInventoryReadGate()
    private var signingOut = false
    private var inventoryScope: AccountInventoryScope? {
        guard !signingOut, let backend, providerDescriptor == AnisetteProviderFactory.shared.currentDescriptor,
              case .signedIn(let context) = snapshot?.phase, context.team.membership == .free,
              context.expiresAt.map({ $0 > Date() }) ?? true else { return nil }
        return .init(backend: ObjectIdentifier(backend), context: context.id, team: context.team.identifier)
    }
    private var visibleInventory: Inventory? {
        guard let inventory, inventory.scope == inventoryScope else { return nil }
        return inventory
    }
    var freeAccountAppCount: Int { visibleInventory?.count ?? 0 }
    var freeAccountInventoryAvailable: Bool { visibleInventory != nil }
    var renewalCandidates: [FreeAccountProfile] { visibleInventory?.candidates ?? [] }

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
                await refreshRenewalCandidates()
                try? await Task.sleep(nanoseconds: 60_000_000_000) // try? ok: cancellation is checked in loop condition
            }
        }
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

    /// Publish counts and candidates together. Neither an old success nor an old
    /// failure may overwrite inventory after a team change or a newer refresh.
    func refreshRenewalCandidates() async {
        guard let scope = inventoryScope, let backend else { invalidateInventory(); return }
        let ticket = inventoryReads.begin(scope)
        do {
            let records = try await backend.listProfiles(contextID: scope.context)
            guard !Task.isCancelled, inventoryReads.accepts(ticket, current: inventoryScope) else { return }
            let profiles = records.compactMap { record -> FreeAccountProfile? in
                guard let expires = record.expiresAt, let bundle = record.bundleIdentifier,
                      let device = record.deviceIdentifier, let identity = record.identityID else { return nil }
                return FreeAccountProfile(id: record.profileUUID, bundleIdentifier: bundle,
                    profileUUID: record.profileUUID, expiresAt: expires,
                    certificateID: identity, deviceIdentifier: device)
            }
            inventory = Inventory(scope: scope, count: Set(profiles.filter { !$0.isExpired }.map(\.bundleIdentifier)).count,
                                  candidates: profiles.filter { $0.isExpiringSoon })
        } catch {
            guard !Task.isCancelled, inventoryReads.accepts(ticket, current: inventoryScope) else { return }
            inventory = nil
            lastError = error.localizedDescription
        }
    }

    private func invalidateInventory() {
        inventoryReads.invalidate()
        inventory = nil
    }

    // MARK: - Backend Initialization

    /// Initializes the backend with the current provider configuration.
    /// Serialize changes: close old operations before constructing a backend for
    /// the current descriptor. Construction does not log in or grant anisette consent.
    @Published private(set) var selectedSlot: NativeSigning.NativeAccountSlot = .primary

    func synchronizeProvider(slot: NativeSigning.NativeAccountSlot? = nil) async {
        let prior = providerUpdate
        let update = Task { @MainActor [weak self] in
            await prior?.value
            guard let self else { return }
            let desired = AnisetteProviderFactory.shared.currentDescriptor
            let target = slot ?? self.selectedSlot
            if self.backend != nil, self.selectedSlot == target, self.providerDescriptor == desired { return }
            await self.shutdown()
            self.selectedSlot = target
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
            let backend = try NativeAccountBackend(provider: descriptor, slot: selectedSlot)
            self.backend = backend
            self.isBackendReady = true
            RenewalRenewabilityState.shared.setAccountSessionReady(false)
            self.lastError = nil
            startEventObservation()
            Task { await refreshSnapshot() }
        } catch {
            logger.error("Failed to initialize NativeAccountBackend: \(error.localizedDescription, privacy: .public)")
            self.lastError = error.localizedDescription
            self.isBackendReady = false
            RenewalRenewabilityState.shared.setAccountSessionReady(false)
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
            let previousScope = inventoryScope
            self.snapshot = snapshot
            let hasRenewableFreeAccountSession: Bool
            if isBackendReady, !signingOut,
               case .signedIn(let context) = snapshot.phase,
               context.team.membership == .free,
               context.expiresAt.map({ $0 > Date() }) ?? true {
                hasRenewableFreeAccountSession = true
            } else {
                hasRenewableFreeAccountSession = false
            }
            RenewalRenewabilityState.shared.setAccountSessionReady(hasRenewableFreeAccountSession)
            if inventoryScope != previousScope { invalidateInventory() }
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

    func revalidate() async throws -> NativeAccountOperation {
        let backend = try configuredBackend()
        let consent = try await backend.recordExplicitAnisetteConsent()
        let operation = try await backend.revalidate(consent: consent)
        guard self.backend === backend, !Task.isCancelled else {
            _ = await backend.cancelAuthentication(operation: operation.id)
            throw CancellationError()
        }
        await refreshSnapshot()
        return operation
    }

    /// 2FA prompt exposed to the app UI without leaking `SideSign` types into views.
    struct TwoFactorChallenge: Identifiable, Equatable, Sendable {
        let operationID: UUID
        let id: UUID
        let isRetry: Bool
    }

    func challenges(for operation: NativeAccountOperation) -> AsyncStream<TwoFactorChallenge> {
        AsyncStream { continuation in
            let task = Task {
                for await challenge in operation.challenges {
                    continuation.yield(
                        TwoFactorChallenge(
                            operationID: challenge.operation,
                            id: challenge.id,
                            isRetry: challenge.isRetry
                        )
                    )
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Submits a 2FA verification code string for a pending challenge.
    func submitTwoFactorCode(_ code: String, operationID: UUID, challengeID: UUID) async throws -> Bool {
        try await submitTwoFactor(.verificationCode(code), operationID: operationID, challengeID: challengeID)
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
        guard !signingOut else { throw NativeAccountBackendError.busy }
        signingOut = true
        RenewalRenewabilityState.shared.setAccountSessionReady(false)
        invalidateInventory()
        defer { signingOut = false }
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

    func reconcileRegistration(contextID: UUID, subject: NativeRegistrationSubject) async throws -> NativeRegistrationResult {
        let backend = try configuredBackend()
        let consent = try await backend.recordExplicitAnisetteConsent()
        return try await backend.reconcileAccountRegistration(contextID: contextID, subject: subject, consent: consent)
    }

    func renewApprovedProfile(contextID: UUID, target: NativeAccountProfileTarget, baselineDigest: String) async throws -> NativeAccountProfileResult {
        let backend = try configuredBackend()
        let consent = try await backend.recordExplicitAnisetteConsent()
        return try await backend.renewExplicitlyApprovedProfile(contextID: contextID, target: target,
            baselineDigest: baselineDigest, consent: consent)
    }

    func reconcileProfile(contextID: UUID, target: NativeAccountProfileTarget) async throws -> NativeAccountProfileResult {
        let backend = try configuredBackend()
        let consent = try await backend.recordExplicitAnisetteConsent()
        return try await backend.reconcileAccountProvisioningProfile(contextID: contextID, target: target, consent: consent)
    }

    // MARK: - Certificate Store Handoff

    /// Mints a separate, short-lived, single-use grant for private-key export.
    /// Provisioning approval and anisette consent do not authorize this step.
    func recordKeyExportConsent(contextID: UUID, identityID: UUID) async throws -> NativeKeyExportConsent {
        let backend = try configuredBackend()
        return try await backend.recordExplicitKeyExportConsent(contextID: contextID, identityID: identityID)
    }

    /// Exports an authenticated native identity/profile pair into the ordinary
    /// certificate store. Signing and installation remain separate user actions
    /// in the existing pipeline; this method never starts either one.
    func exportToCertificateStore(
        contextID: UUID,
        profile: NativeAccountProfileResult,
        identityID: UUID,
        bundleIdentifier: String,
        deviceIdentifier: String,
        consent: NativeKeyExportConsent
    ) async throws -> String {
        let backend = try configuredBackend()
        guard case .signedIn(let context) = snapshot?.phase, context.id == contextID,
              context.team.membership == .free,
              let identity = await getIdentityDetails(identityID: identityID) else {
            throw NativeSigningError.provisioningFailed(.localized("The Apple account or signing identity changed. Review the current account and try again."))
        }
        let request = NativeSigningHandoffCoordinator.Request(profileUUID: profile.profileUUID,
            expiresAt: profile.expiresAt, teamIdentifier: context.team.identifier,
            identity: identity, bundleIdentifier: bundleIdentifier, deviceIdentifier: deviceIdentifier)
        let provider = providerDescriptor
        do {
            let certificateUUID = try await NativeSigningHandoffCoordinator().run(request: request, exportProfile: {
                let anisetteConsent = try await backend.recordExplicitAnisetteConsent()
                return try await backend.exportProvisioningProfile(contextID: contextID,
                    profileUUID: profile.profileUUID, identityID: identityID,
                    bundleIdentifier: bundleIdentifier, deviceIdentifier: deviceIdentifier,
                    consent: anisetteConsent)
            }, backendIsCurrent: {
                guard self.backend === backend, self.providerDescriptor == provider,
                      AnisetteProviderFactory.shared.currentDescriptor == provider,
                      case .signedIn(let current) = self.snapshot?.phase else { return false }
                return current.id == contextID && (current.expiresAt.map { $0 > Date() } ?? true)
            }, exportIdentity: { password in
                try await backend.exportSigningIdentity(contextID: contextID,
                    identityID: identityID, password: password, consent: consent)
            }, importCertificate: { p12URL, provisionURL, password, name in
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                    CertificateManagementService.importCertificateFilesIdentified(p12URL: p12URL, provisionURL: provisionURL,
                        p12Password: password, certificateName: name) { continuation.resume(with: $0) }
                }
            })
            // Provenance is written only after the importer commits this UUID.
            // No display name, team string or file path participates.
            SigningIdentityProvenanceStore.record(.appleAccountHandoff, uuid: certificateUUID)
            lastError = nil
            return certificateUUID
        } catch {
            if !(error is CancellationError) && !Task.isCancelled {
                lastError = error.localizedDescription
            }
            throw error
        }
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
        let observation = eventTask
        observation?.cancel()
        eventTask = nil
        let previousBackend = backend
        backend = nil
        isBackendReady = false
        RenewalRenewabilityState.shared.setAccountSessionReady(false)
        providerDescriptor = nil
        snapshot = nil
        invalidateInventory()
        lastError = nil
        await previousBackend?.shutdown()
        await observation?.value
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
    ///
    /// Throws `AnisetteConsentError.invalidProvider` when the endpoint or identity
    /// fails the descriptor's validation (HTTPS-only, no embedded credentials,
    /// non-empty bounded strings) instead of trapping the process.
    static func defaultHTTPS(endpoint: URL, identity: String, policyRevision: Int) throws -> AnisetteProviderDescriptor {
        try AnisetteProviderDescriptor(
            identifier: identity,
            displayName: "Custom Anisette Server",
            policyRevision: String(policyRevision),
            endpoint: endpoint
        )
    }
}
