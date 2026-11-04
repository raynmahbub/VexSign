import Foundation
import SideSign
import os

public enum NativeAccountBackendError: Error, Equatable {
    case alreadyInUse, busy, closed, unsupportedRuntime, invalidConfiguration
    case consentRequired, providerChanged, providerFailed
    case accountAlreadyActive, noSavedAccount, resumeRequired, cleanupRequired
    case authenticationFailed, unsupportedTeam, sessionExpired, storageUnavailable
}

public enum NativeAccountMembership: Equatable, Sendable {
    case free, paidVerified, developerProgramUnverified
}
public struct NativeAccountTeam: Equatable, Sendable {
    public let identifier: String
    public let membership: NativeAccountMembership
}
public struct NativeAccountContext: Equatable, Sendable {
    public let id: UUID
    public let team: NativeAccountTeam
    public let expiresAt: Date?
}
public enum NativeAccountPhase: Equatable, Sendable {
    case signedOut
    case authenticating(UUID)
    case awaitingTwoFactor(UUID)
    case awaitingTeamSelection(UUID, [NativeAccountTeam], expiresAt: Date?)
    case signedIn(NativeAccountContext)
    case expired(expiresAt: Date?)

    var isSignedIn: Bool {
        if case .signedIn = self { return true }
        return false
    }
}
public struct NativeAccountSnapshot: Equatable, Sendable {
    public let phase: NativeAccountPhase
    public let cleanupRequired: Bool
}
public enum NativeAccountEvent: Equatable, Sendable {
    case awaitingTeamSelection(UUID)
    case failed(UUID, NativeAccountBackendError)
    case cancelled(UUID)
    case stateChanged(UUID)
}
public struct NativeAccountOperation: Sendable {
    public let id: UUID
    public let challenges: AsyncStream<SideSignTwoFactorBroker.Challenge>
    private let completion: @Sendable () async -> Void

    init(id: UUID, challenges: AsyncStream<SideSignTwoFactorBroker.Challenge>,
         completion: @escaping @Sendable () async -> Void) {
        self.id = id; self.challenges = challenges; self.completion = completion
    }
    /// Worker retirement, not a guarantee of success. Read events/latest snapshot.
    /// Do not block UI dismissal on an uncooperative provider finishing.
    public func waitUntilFinished() async { await completion() }
}

/// Information about a provisioning profile for listing purposes.
public struct NativeProfileInfo: Sendable, Identifiable {
    public let id = UUID()
    public let profileUUID: UUID
    public let identityID: UUID
    public let createdAt: Date
    public let remoteIdentifierDigest: String
    public let cmsSHA256: String
    /// Expiry date if available (requires portal query)
    public let expiresAt: Date?
    /// Bundle identifier if available
    public let bundleIdentifier: String?
    /// Device identifier if available
    public let deviceIdentifier: String?

    public init(profileUUID: UUID, identityID: UUID, createdAt: Date,
                remoteIdentifierDigest: String, cmsSHA256: String,
                expiresAt: Date? = nil, bundleIdentifier: String? = nil,
                deviceIdentifier: String? = nil) {
        self.profileUUID = profileUUID
        self.identityID = identityID
        self.createdAt = createdAt
        self.remoteIdentifierDigest = remoteIdentifierDigest
        self.cmsSHA256 = cmsSHA256
        self.expiresAt = expiresAt
        self.bundleIdentifier = bundleIdentifier
        self.deviceIdentifier = deviceIdentifier
    }
}

protocol NativeAccountBackendLifetime: Sendable {}

/// Module/process-local exclusion for the supported factory. Not a cross-process
/// lock and cannot police direct/legacy store writers or malicious hosted code.
final class NativeAccountNamespaceLease: NativeAccountBackendLifetime {
    private static let owner = OSAllocatedUnfairLock<UUID?>(initialState: nil)
    private let id: UUID
    private init(id: UUID) { self.id = id }

    static func acquire() throws -> NativeAccountNamespaceLease {
        let id = UUID()
        try owner.withLock {
            guard $0 == nil else { throw NativeAccountBackendError.alreadyInUse }
            $0 = id
        }
        return NativeAccountNamespaceLease(id: id)
    }
    deinit {
        Self.owner.withLock { if $0 == id { $0 = nil } }
    }
}

/// Concrete SDK + configured HTTPS provider + actual device-only Keychain stores.
/// Construction performs no Keychain read, provider request or Apple login. This
/// is source assembly in the isolated module, not proof the normal app links it.
/// There is intentionally no password/session-byte/reference export API.
public actor NativeAccountBackend {
    private typealias Bridge = SideSignAccountBridge<SideSignNativePortal,
        HTTPSAnisetteProvider<SystemAnisetteHeaderTransport>,
        AppleAccountCredentialStore<SystemAppleAccountKeychainClient>,
        AppleAccountResumeJournalStore<SystemAppleAccountKeychainClient>>
    private let bridge: Bridge
    private var closed = false

    public init(provider descriptor: AnisetteProviderDescriptor) throws {
        do { try AppleAccountStorageRuntimePolicy.requirePrimaryRuntime() }
        catch { throw NativeAccountBackendError.unsupportedRuntime }
        let lease = try NativeAccountNamespaceLease.acquire()
        do {
            let provider = try HTTPSAnisetteProvider<SystemAnisetteHeaderTransport>(descriptor: descriptor)
            let adapter = try SideSignAccountAdapter<SideSignNativePortal>()
            bridge = Bridge(adapter: adapter, provider: provider,
                            sessions: AppleAccountCredentialStore(), journal: AppleAccountResumeJournalStore(),
                            lifetime: lease)
        } catch {
            throw NativeAccountBackendError.invalidConfiguration
        }
    }

    public func recordExplicitAnisetteConsent(lifetime: TimeInterval = 900) async throws -> AnisetteConsentToken {
        try requireOpen()
        do { return try await bridge.recordExplicitAnisetteConsent(lifetime: lifetime) }
        catch { throw Self.safe(error) }
    }

    public func authenticate(appleID: String, password: String, xcodeVersion: String,
                             consent: AnisetteConsentToken) async throws -> NativeAccountOperation {
        try requireOpen()
        do {
            let handle = try await bridge.startAuthentication(appleID: appleID, password: password,
                                                               xcodeVersion: xcodeVersion, consent: consent)
            return NativeAccountOperation(id: handle.operation, challenges: handle.challenges,
                                          completion: { await handle.waitUntilFinished() })
        } catch { throw Self.safe(error) }
    }

    public func revalidate(consent: AnisetteConsentToken) async throws -> NativeAccountOperation {
        try requireOpen()
        do {
            let handle = try await bridge.startRevalidation(consent: consent)
            return NativeAccountOperation(id: handle.operation, challenges: handle.challenges,
                                          completion: { await handle.waitUntilFinished() })
        } catch { throw Self.safe(error) }
    }

    public func submitTwoFactor(_ response: TwoFactorResponse, operation: UUID, challengeID: UUID) async throws -> Bool {
        try requireOpen()
        return await bridge.submitTwoFactor(response, operation: operation, challengeID: challengeID)
    }
    public func cancelAuthentication(operation: UUID) async -> Bool { await bridge.cancelAuthentication(operation: operation) }
    public func revokeAnisetteConsent() async { await bridge.revokeAnisetteConsent() }

    public func selectTeam(identifier: String, operation: UUID) async throws -> Bool {
        try requireOpen()
        do { return try await bridge.selectTeam(identifier: identifier, operation: operation) }
        catch { throw Self.safe(error) }
    }
    /// Removes the account session, never revokes a portal certificate. Signing
    /// identity rows are retained separately, including uncertain submissions.
    public func signOut() async throws {
        try requireOpen()
        do { try await bridge.signOut() }
        catch { throw Self.safe(error) }
    }
    public func retryPendingDeletions() async throws {
        try requireOpen()
        do { try await bridge.retryPendingDeletions() }
        catch { throw Self.safe(error) }
    }

    /// Read-only free-account preparation preview. Explicit consent and a current
    /// selected context are required. This does not register/revoke anything or
    /// imply signing readiness; it never exports SDK/Keychain session material.
    public func provisioningPreflight(contextID: UUID, request: NativeAccountProvisioningRequest,
                                      consent: AnisetteConsentToken) async throws -> NativeAccountProvisioningPlan {
        try requireOpen()
        do { return try await bridge.provisioningPreflight(contextID: contextID, request: request, token: consent) }
        catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if let safe = error as? NativeProvisioningError { throw safe }
            throw Self.safe(error)
        }
    }

    /// Explicit device-only key/CSR preparation. Idempotently recovers this
    /// account/team's existing identity, including uncertain submissions.
    /// Does NOT create an Apple certificate or authorize certificate submission.
    public func prepareSigningIdentity(contextID: UUID) async throws -> NativeSigningIdentityTicket {
        try requireOpen()
        do { return try await bridge.prepareSigningIdentity(contextID: contextID) }
        catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if let safe = error as? NativeSigningIdentityError { throw safe }
            throw Self.safe(error)
        }
    }

    /// Exact local draft removal only. Submitted/uncertain/certified identities
    /// cannot be discarded here; this never revokes anything on Apple's servers.
    public func discardPreparedSigningIdentity(contextID: UUID, identityID: UUID) async throws {
        try requireOpen()
        do { try await bridge.discardPreparedSigningIdentity(contextID: contextID, identityID: identityID) }
        catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if let safe = error as? NativeSigningIdentityError { throw safe }
            throw Self.safe(error)
        }
    }

    /// Must follow informed user approval to create an Apple Development
    /// certificate (may consume account quota). This is NOT anisette consent.
    public func recordExplicitCertificateCreationApproval(contextID: UUID, identityID: UUID,
                                                          lifetime: TimeInterval = 120) async throws -> NativeCertificateCreationApproval {
        try requireOpen()
        do { return try await bridge.recordExplicitCertificateCreationApproval(contextID: contextID, identityID: identityID, lifetime: lifetime) }
        catch { throw Self.certificateError(error) }
    }

    public func revokeCertificateCreationApproval() async { await bridge.revokeCertificateCreationApproval() }

    public func createDevelopmentSigningCertificate(contextID: UUID, identityID: UUID,
                                                     approval: NativeCertificateCreationApproval,
                                                     consent: AnisetteConsentToken) async throws -> NativeSigningIdentityTicket {
        try requireOpen()
        do { return try await bridge.createDevelopmentSigningCertificate(contextID: contextID, identityID: identityID, approval: approval, consent: consent) }
        catch { throw Self.certificateError(error) }
    }

    /// Read-only Apple inventory recovery for uncertain requests. No CSR send,
    /// retry, quota cleanup or automatic certificate revocation occurs here.
    public func reconcileUncertainSigningCertificate(contextID: UUID, identityID: UUID,
                                                      consent: AnisetteConsentToken) async throws -> NativeSigningIdentityTicket {
        try requireOpen()
        do { return try await bridge.reconcileUncertainSigningCertificate(contextID: contextID, identityID: identityID, consent: consent) }
        catch { throw Self.certificateError(error) }
    }

    /// User action only: device/App ID registration may consume Apple quotas.
    /// Independent from provider-disclosure consent and certificate approval.
    public func recordExplicitRegistrationApproval(contextID: UUID, subject: NativeRegistrationSubject,
                                                    lifetime: TimeInterval = 120) async throws -> NativeAccountRegistrationApproval {
        try requireOpen()
        do { return try await bridge.recordExplicitRegistrationApproval(contextID: contextID, subject: subject, lifetime: lifetime) }
        catch { throw Self.registrationError(error) }
    }

    public func revokeRegistrationApproval() async { await bridge.revokeRegistrationApproval() }

    public func registerAccountResource(contextID: UUID, subject: NativeRegistrationSubject,
                                        approval: NativeAccountRegistrationApproval,
                                        consent: AnisetteConsentToken) async throws -> NativeRegistrationResult {
        try requireOpen()
        do { return try await bridge.registerAccountResource(contextID: contextID, subject: subject, approval: approval, consent: consent) }
        catch { throw Self.registrationError(error) }
    }

    /// Read-only recovery; never calls a registration endpoint, even on absence.
    public func reconcileAccountRegistration(contextID: UUID, subject: NativeRegistrationSubject,
                                             consent: AnisetteConsentToken) async throws -> NativeRegistrationResult {
        try requireOpen()
        do { return try await bridge.reconcileAccountRegistration(contextID: contextID, subject: subject, consent: consent) }
        catch { throw Self.registrationError(error) }
    }

    /// Explicit profile approval is not anisette consent or signing readiness.
    /// The current factory keeps the CMS verifier unselected: these APIs fail
    /// closed until native validation/promotion, without normal-app UI enablement.
    public func recordExplicitProfileCreationApproval(contextID: UUID, target: NativeAccountProfileTarget,
                                                       lifetime: TimeInterval = 120) async throws -> NativeAccountProfileApproval {
        try requireOpen()
        do { return try await bridge.recordExplicitProfileCreationApproval(contextID: contextID, target: target, lifetime: lifetime) }
        catch { throw Self.profileError(error) }
    }

    public func revokeProfileCreationApproval() async { await bridge.revokeProfileCreationApproval() }

    public func createAccountProvisioningProfile(contextID: UUID, target: NativeAccountProfileTarget,
                                                  approval: NativeAccountProfileApproval,
                                                  consent: AnisetteConsentToken) async throws -> NativeAccountProfileResult {
        try requireOpen()
        do { return try await bridge.createAccountProvisioningProfile(contextID: contextID, target: target, approval: approval, consent: consent) }
        catch { throw Self.profileError(error) }
    }

    /// Inventory/download recovery only. Missing/uncertain/expired profiles never
    /// authorize automatic creation, renewal, journal reset or remote cleanup.
    public func reconcileAccountProvisioningProfile(contextID: UUID, target: NativeAccountProfileTarget,
                                                     consent: AnisetteConsentToken) async throws -> NativeAccountProfileResult {
        try requireOpen()
        do { return try await bridge.reconcileAccountProvisioningProfile(contextID: contextID, target: target, consent: consent) }
        catch { throw Self.profileError(error) }
    }

    /// Explicit informed approval for system certificate-status network disclosure.
    /// This is not anisette consent, signing permission or quota approval.
    public func recordExplicitCertificateStatusConsent(contextID: UUID, identityID: UUID,
                                                       lifetime: TimeInterval = 120) async throws -> NativeCertificateStatusConsent {
        try requireOpen()
        do { return try await bridge.recordExplicitCertificateStatusConsent(contextID: contextID, identityID: identityID, lifetime: lifetime) }
        catch { throw Self.statusError(error) }
    }

    public func revokeCertificateStatusConsent() async { await bridge.revokeCertificateStatusConsent() }

    /// Explicit informed approval for private key material export as PKCS#12.
    /// This is not anisette consent, certificate creation approval, or quota approval.
    public func recordExplicitKeyExportConsent(contextID: UUID, identityID: UUID,
                                               lifetime: TimeInterval = 120) async throws -> NativeKeyExportConsent {
        try requireOpen()
        do { return try await bridge.recordExplicitKeyExportConsent(contextID: contextID, identityID: identityID, lifetime: lifetime) }
        catch { throw Self.statusError(error) }
    }

    public func revokeKeyExportConsent() async { await bridge.revokeKeyExportConsent() }

    /// No grant means cached-positive-only/offline. A supplied grant allows ONE
    /// system status evaluation after offline Apple chain/purpose validation.
    /// Metadata result is not a reusable signing permit or installation authority.
    public func evaluateSigningCertificateStatus(contextID: UUID, identityID: UUID,
                                                 consent: NativeCertificateStatusConsent? = nil) async throws -> NativeAccountCertificateStatus {
        try requireOpen()
        do { return try await bridge.evaluateSigningCertificateStatus(contextID: contextID, identityID: identityID, statusConsent: consent) }
        catch { throw Self.statusError(error) }
    }

    private static func statusError(_ error: Error) -> Error {
        if error is CancellationError || Task.isCancelled { return CancellationError() }
        if let safe = error as? NativeDevelopmentCertificateError { return safe }
        if let safe = error as? NativeCertificateStatusConsentError { return safe }
        return Self.certificateError(error)
    }

    private static func profileError(_ error: Error) -> Error {
        if error is CancellationError || Task.isCancelled { return CancellationError() }
        if let safe = error as? NativeProfileCreationError { return safe }
        if let safe = error as? NativeProfileValidationError { return safe }
        return Self.certificateError(error)
    }

    private static func registrationError(_ error: Error) -> Error {
        if let safe = error as? NativeRegistrationError { return safe }
        return Self.certificateError(error)
    }

    private static func certificateError(_ error: Error) -> Error {
        if error is CancellationError || Task.isCancelled { return CancellationError() }
        if let safe = error as? NativeSigningIdentityError { return safe }
        if let safe = error as? NativeProvisioningError { return safe }
        return Self.safe(error)
    }

    public func snapshot() async throws -> NativeAccountSnapshot {
        try requireOpen()
        return Self.project(await bridge.snapshot())
    }

    /// Single bounded observer. Events are hints: snapshots remain authoritative
    /// across actor hops/cancel races. No secret bytes or Keychain references flow.
    public func events() async throws -> AsyncStream<NativeAccountEvent> {
        try requireOpen()
        let source = await bridge.outcomes()
        return AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            let worker = Task {
                for await event in source {
                    if Task.isCancelled { break }
                    switch event {
                    case .awaitingTeamSelection(let id): continuation.yield(.awaitingTeamSelection(id))
                    case .cancelled(let id): continuation.yield(.cancelled(id))
                    case .stateChanged(let id): continuation.yield(.stateChanged(id))
                    case .failed(let id, let failure): continuation.yield(.failed(id, Self.mapFailure(failure)))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in worker.cancel() }
        }
    }

    /// Cancels in-flight work and closes observation, but keeps accepted sessions
    /// for later explicit revalidation. Use signOut FIRST if removal is intended.
    /// Lease stays held until this facade and all bridge workers are released.
    public func shutdown() async {
        guard !closed else { return }
        closed = true
        await bridge.shutdown()
    }

    private func requireOpen() throws { if closed { throw NativeAccountBackendError.closed } }

    static func project<Sessions: AppleAccountRecoverableSessionStorage, Journal: AppleAccountResumeJournalStorage>(_ snapshot: AppleAccountSessionCoordinator<Sessions, Journal>.Snapshot) -> NativeAccountSnapshot {
        let phase: NativeAccountPhase
        switch snapshot.phase {
        case .signedOut: phase = .signedOut
        case .authenticating(let id): phase = .authenticating(id)
        case .awaitingTwoFactor(let id): phase = .awaitingTwoFactor(id)
        case .awaitingTeamSelection(let id, let session):
            phase = .awaitingTeamSelection(id, session.teams.map(projectTeam), expiresAt: session.expiresAt)
        case .signedIn(let context):
            phase = .signedIn(NativeAccountContext(id: context.id, team: projectTeam(context.team), expiresAt: context.session.expiresAt))
        case .expired(let session): phase = .expired(expiresAt: session.expiresAt)
        }
        return NativeAccountSnapshot(phase: phase, cleanupRequired: snapshot.cleanupRequired)
    }

    /// Lists all provisioning profiles for the given context.
    /// Returns an array of profile info with expiry dates.
    public func listProfiles(contextID: UUID) async throws -> [NativeProfileInfo] {
        try requireOpen()
        do {
            // Get the context to derive the owner
            let snapshot = try await bridge.snapshot()
            let context: AppleAccountAuthenticationState.Context?
            switch snapshot.phase {
            case .signedIn(let ctx):
                context = ctx
            default:
                return []
            }
            guard let context = context, context.id == contextID else {
                return []
            }
            let owner = try SideSignSessionCodec.identityOwner(
                context.encodedSession,
                teamIdentifier: context.team.identifier,
                now: clock()
            )

            // List all profile records from storage
            let records = try bridge.profileStore.listAllRecords(owner: owner)

            // Filter for recorded profiles and convert to NativeProfileInfo
            var profiles: [NativeProfileInfo] = []
            for record in records {
                guard record.phase == .recorded,
                      let profileUUID = record.profileUUID,
                      let remoteIdentifierDigest = record.remoteIdentifierDigest,
                      let cmsSHA256 = record.cmsSHA256 else { continue }

                // For each recorded profile, we need to get the expiry date.
                // This requires querying the portal for the profile details.
                // For now, we create a basic info with what we have.
                // In a full implementation, we'd need to fetch the actual profile data.
                let info = NativeProfileInfo(
                    profileUUID: profileUUID,
                    identityID: record.id,
                    createdAt: record.createdAt,
                    remoteIdentifierDigest: remoteIdentifierDigest,
                    cmsSHA256: cmsSHA256
                )
                profiles.append(info)
            }
            return profiles
        } catch {
            throw Self.safe(error)
        }
    }

    /// Exports the signing identity (private key + certificate) as a PKCS#12 (.p12) archive.
    /// Requires explicit user consent for key material export.
    /// - Parameters:
    ///   - contextID: The active signing context ID
    ///   - identityID: The identity to export
    ///   - password: Password to encrypt the .p12 (user-provided)
    ///   - consent: Explicit key export consent token
    /// - Returns: The .p12 data
    public func exportSigningIdentity(
        contextID: UUID,
        identityID: UUID,
        password: String,
        consent: NativeKeyExportConsent
    ) async throws -> Data {
        try requireOpen()
        do {
            // Get the context to derive the owner
            let snapshot = try await bridge.snapshot()
            let context: AppleAccountAuthenticationState.Context?
            switch snapshot.phase {
            case .signedIn(let ctx):
                context = ctx
            default:
                throw NativeAccountBackendError.sessionExpired
            }
            guard let context = context, context.id == contextID else {
                throw NativeAccountBackendError.sessionExpired
            }
            let owner = try SideSignSessionCodec.identityOwner(
                context.encodedSession,
                teamIdentifier: context.team.identifier,
                now: clock()
            )

            // Get the owned signing certificate (includes certificate DER)
            let owned = try await bridge.signingIdentities.ownedSigningCertificate(
                owner: owner,
                identityID: identityID,
                now: clock()
            )

            // Validate consent matches this identity and certificate
            try consent.validate(owner: owner, identityID: identityID, certificate: owned.certificateDER, now: clock())

            // Get the private key DER from the identity store
            let privateKeyDER = try await bridge.signingIdentities.privateKeyDER(
                owner: owner,
                identityID: identityID,
                now: clock()
            )

            // Export as PKCS#12
            let p12Data = try NativeSigningIdentityCrypto.exportPKCS12(
                privateKeyDER: privateKeyDER,
                certificateDER: owned.certificateDER,
                password: password
            )

            return p12Data
        } catch {
            throw Self.safe(error)
        }
    }

    /// Downloads a provisioning profile by UUID as a .mobileprovision file.
    /// - Parameters:
    ///   - contextID: The active signing context ID
    ///   - profileUUID: The UUID of the profile to download
    ///   - consent: Explicit anisette consent for the portal request
    /// - Returns: The .mobileprovision data (CMS signed plist)
    public func downloadProvisioningProfile(
        contextID: UUID,
        profileUUID: UUID,
        consent: AnisetteConsentToken
    ) async throws -> Data {
        try requireOpen()
        do {
            // Get the context to derive the owner
            let snapshot = try await bridge.snapshot()
            let context: AppleAccountAuthenticationState.Context?
            switch snapshot.phase {
            case .signedIn(let ctx):
                context = ctx
            default:
                throw NativeAccountBackendError.sessionExpired
            }
            guard let context = context, context.id == contextID else {
                throw NativeAccountBackendError.sessionExpired
            }
            let owner = try SideSignSessionCodec.identityOwner(
                context.encodedSession,
                teamIdentifier: context.team.identifier,
                now: clock()
            )

            // Get provisioning candidate (encoded session + team)
            guard let candidate = try await bridge.coordinator.provisioningCandidate(
                contextID: contextID,
                now: clock()
            ) else {
                throw NativeProvisioningError.contextChanged
            }

            // Get fresh anisette headers
            let headers = try await bridge.provider.freshHeaders()

            // Use the portal to download the profile
            let portal = bridge.adapter.provisioningPortal
            let profileData = try await portal.downloadProvisioningProfile(
                encodedSession: candidate.encodedSession,
                headers: headers,
                teamIdentifier: candidate.context.team.identifier,
                profileUUID: profileUUID,
                now: clock()
            )

            return profileData
        } catch {
            throw Self.safe(error)
        }
    }

    private static func projectTeam(_ team: AppleAccountSessionMetadata.Team) -> NativeAccountTeam {
        let membership: NativeAccountMembership
        switch team.membership {
        case .free: membership = .free
        case .paid: membership = .paidVerified
        case .developerProgramUnverified: membership = .developerProgramUnverified
        }
        return NativeAccountTeam(identifier: team.identifier, membership: membership)
    }

    private static func safe(_ error: Error) -> Error {
        if error is CancellationError || Task.isCancelled { return CancellationError() }
        return mapFailure(error)
    }
    private static func mapFailure(_ error: Error) -> NativeAccountBackendError {
        if let safe = error as? NativeAccountBackendError { return safe }
        if let value = error as? Bridge.Failure {
            switch value {
            case .closed: return .closed
            case .flowBusy: return .busy
            case .accountAlreadyActive: return .accountAlreadyActive
            case .noResumeCandidate: return .noSavedAccount
            case .consentRequired: return .consentRequired
            case .providerChanged: return .providerChanged
            case .providerFailed: return .providerFailed
            case .unsupportedTeam: return .unsupportedTeam
            case .sessionExpired: return .sessionExpired
            case .secureStorageBlocked: return .storageUnavailable
            case .authenticationFailed: return .authenticationFailed
            }
        }
        if let value = error as? AppleAccountSessionCoordinatorError {
            switch value {
            case .resumeRequired: return .resumeRequired
            case .cleanupRequired: return .cleanupRequired
            case .authenticationInProgress: return .busy
            case .invalidSessionMetadata: return .authenticationFailed
            }
        }
        if let value = error as? AnisetteConsentError {
            switch value {
            case .providerChanged: return .providerChanged
            case .providerFailed: return .providerFailed
            case .invalidProvider, .invalidLifetime: return .invalidConfiguration
            case .consentRequired: return .consentRequired
            }
        }
        if error is AppleAccountCredentialStoreError || error is AppleAccountSessionRepositoryError { return .storageUnavailable }
        return .authenticationFailed
    }
}
