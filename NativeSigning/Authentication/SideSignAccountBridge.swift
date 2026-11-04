import Foundation
import SideSign

/// Runs in the isolated native module against byte-identical copies of the app's
/// Foundation lifecycle core. No parallel state machine, credentials UI or default
/// anisette server. Promotion into the app target remains a separate build gate.
actor SideSignAccountBridge<Portal: SideSignAccountPortal, Provider: ConsentedAnisetteProvider,
                           Sessions: AppleAccountRecoverableSessionStorage, Journal: AppleAccountResumeJournalStorage> {
    enum Failure: Error, Equatable, Sendable {
        case closed, flowBusy, accountAlreadyActive, noResumeCandidate
        case consentRequired, providerChanged, providerFailed
        case authenticationFailed, unsupportedTeam, sessionExpired, secureStorageBlocked
    }
    enum Outcome: Equatable, Sendable {
        case awaitingTeamSelection(UUID)
        case failed(UUID, Failure)
        case cancelled(UUID)
        case stateChanged(UUID)
    }
    struct Handle: Sendable {
        let operation: UUID
        let challenges: AsyncStream<SideSignTwoFactorBroker.Challenge>
        fileprivate let worker: Task<Void, Never>

        // Await actual worker retirement, not merely cancellation acknowledgement.
        // Uncooperative providers can still delay this; UI must not block on it.
        func waitUntilFinished() async { await worker.value }
    }
    private enum Input: Sendable {
        case password(appleID: String, password: String, xcodeVersion: String)
        case resume(AppleAccountSessionPersistence<Sessions, Journal>.ResumeCandidate)
    }
    private struct Active: Sendable {
        let operation: UUID
        let broker: SideSignTwoFactorBroker
        let consent: AnisetteConsentToken
        let task: Task<Void, Never>
        let deadline: Task<Void, Never>
    }

    private let coordinator: AppleAccountSessionCoordinator<Sessions, Journal>
    private let adapter: SideSignAccountAdapter<Portal>
    private let provider: Provider
    // Retains the assembly's namespace lease until even cancelled/uncooperative
    // workers have retired. Releasing just the public facade must not unlock it.
    private let lifetime: (any NativeAccountBackendLifetime)?
    private let clock: @Sendable () -> Date
    private var consent = AnisetteConsentGate()
    private var active: Active?
    private var generation = UUID()
    private var setupBusy = false
    private var closed = false
    private var provisioningTask: Task<NativeAccountProvisioningPlan, Error>?
    private var identityTask: Task<NativeSigningIdentityTicket, Error>?
    private var identityDiscardTask: Task<Void, Error>?
    private var certificateTask: Task<NativeSigningIdentityTicket, Error>?
    private var certificateApproval: NativeCertificateCreationApproval?
    private var certificateApprovalEpoch = UUID()
    private var registrationTask: Task<NativeRegistrationResult, Error>?
    private var registrationApproval: NativeAccountRegistrationApproval?
    private var registrationEpoch = UUID()
    private let certificateStatusConsent = NativeCertificateStatusConsentGate()
    private var certificateStatusEpoch = UUID()
    private let keyExportConsent = NativeKeyExportConsentGate()
    private var keyExportEpoch = UUID()
    private var certificateStatusTask: Task<NativeAccountCertificateStatus, Error>?
    private var profileTask: Task<NativeAccountProfileResult, Error>?
    private var profileApproval: NativeAccountProfileApproval?
    private var profileEpoch = UUID()
    private let profileStore: NativeProfileCreationStorageAdapter
    private let profileValidator: NativeProvisioningProfileValidator
    private let registrationStore: NativeRegistrationStorageAdapter
    private let signingIdentities: any NativeSigningIdentityManaging
    private var maintenanceCount = 0
    private var observer: AsyncStream<Outcome>.Continuation?

    init(adapter: SideSignAccountAdapter<Portal>, provider: Provider, sessions: Sessions, journal: Journal,
         clock: @escaping @Sendable () -> Date = { Date() }, lifetime: (any NativeAccountBackendLifetime)? = nil,
         identities: (any NativeSigningIdentityManaging)? = nil,
         registrations: (any NativeRegistrationStorage)? = nil,
         profiles: (any NativeProfileCreationStorage)? = nil,
         profileValidator: NativeProvisioningProfileValidator = .init()) {
        self.adapter = adapter
        self.profileValidator = profileValidator
        profileStore = NativeProfileCreationStorageAdapter(base: profiles ??
            NativeProfileCreationKeychainStore(client: SystemAppleAccountKeychainClient()))
        self.lifetime = lifetime
        registrationStore = NativeRegistrationStorageAdapter(base: registrations ??
            NativeRegistrationKeychainStore(client: SystemAppleAccountKeychainClient()))
        signingIdentities = identities ?? NativeSigningIdentityCoordinator(
            store: NativeSigningIdentityKeychainStore(client: SystemAppleAccountKeychainClient()),
            generator: NativeSigningIdentityCrypto())
        self.provider = provider
        self.clock = clock
        coordinator = AppleAccountSessionCoordinator(sessions: sessions, journal: journal)
    }

    deinit { observer?.finish() }

    func shutdown() async {
        guard !closed else { return }
        closed = true
        generation = UUID() // invalidates setup even before a worker is registered
        await revokeAnisetteConsent()
        observer?.finish()
        observer = nil
    }

    func outcomes() -> AsyncStream<Outcome> {
        observer?.finish()
        if closed { return AsyncStream { $0.finish() } }
        return AsyncStream(bufferingPolicy: .bufferingNewest(8)) { observer = $0 }
    }

    /// Must follow informed user approval in the future UI, never app startup.
    func recordExplicitAnisetteConsent(lifetime: TimeInterval = 900) throws -> AnisetteConsentToken {
        guard !closed else { throw Failure.closed }
        guard !setupBusy, maintenanceCount == 0, provisioningTask == nil, identityTask == nil, identityDiscardTask == nil, certificateTask == nil, registrationTask == nil, profileTask == nil, certificateStatusTask == nil, active == nil else { throw Failure.flowBusy }
        return try consent.recordExplicitConsent(for: provider.descriptor, now: clock(), lifetime: lifetime)
    }

    func startAuthentication(appleID: String, password: String, xcodeVersion: String,
                             consent token: AnisetteConsentToken) async throws -> Handle {
        try await start(input: .password(appleID: appleID, password: password, xcodeVersion: xcodeVersion), token: token)
    }

    func startRevalidation(consent token: AnisetteConsentToken) async throws -> Handle {
        try await start(input: nil, token: token)
    }

    private func start(input: Input?, token: AnisetteConsentToken) async throws -> Handle {
        try Task.checkCancellation()
        guard !closed else { throw Failure.closed }
        guard !setupBusy, maintenanceCount == 0, provisioningTask == nil, identityTask == nil, identityDiscardTask == nil, certificateTask == nil, registrationTask == nil, profileTask == nil, certificateStatusTask == nil else { throw Failure.flowBusy }
        try consent.require(token, provider: provider.descriptor, now: clock())
        setupBusy = true
        defer { setupBusy = false }
        let beforeSetup = generation
        let operation: UUID
        let actualInput: Input
        if let input {
            guard let value = try await coordinator.beginAuthentication() else { throw Failure.accountAlreadyActive }
            operation = value
            actualInput = input
        } else {
            guard let resumed = try await coordinator.beginRevalidation() else { throw Failure.noResumeCandidate }
            operation = resumed.operation
            actualInput = .resume(resumed.candidate)
        }
        // Sign-out/cancellation during the coordinator hop must not start SDK work.
        guard generation == beforeSetup, !Task.isCancelled else {
            _ = await coordinator.failAuthentication(operation: operation)
            throw CancellationError()
        }
        generation = UUID()
        let flow = generation
        let previous = active
        active = nil
        previous?.task.cancel()
        previous?.deadline.cancel()
        await previous?.broker.cancel()
        let broker = SideSignTwoFactorBroker(operation: operation)
        let challenges = await broker.challengeEvents()
        guard generation == flow, !Task.isCancelled else {
            await broker.cancel()
            _ = await coordinator.failAuthentication(operation: operation)
            throw CancellationError()
        }
        let task = Task { await self.run(operation: operation, flow: flow, input: actualInput, token: token, broker: broker) }
        let remaining = max(0, min(900, token.expiresAt.timeIntervalSince(clock())))
        let delay = remaining.isFinite ? UInt64(remaining * 1_000_000_000) : 0
        let deadline = Task {
            do { try await Task.sleep(nanoseconds: delay) }
            catch { return }
            await self.expireConsent(operation: operation, flow: flow)
        }
        active = Active(operation: operation, broker: broker, consent: token, task: task, deadline: deadline)
        // Late registration is guarded inside the coordinator. A very fast result
        // may already be accepted/rejected; never delete a record for that reason.
        _ = await coordinator.attachAuthenticationTask(task, operation: operation)
        guard generation == flow, !Task.isCancelled else {
            _ = await cancelAuthentication(operation: operation)
            throw CancellationError()
        }
        return Handle(operation: operation, challenges: challenges, worker: task)
    }

    private func run(operation: UUID, flow: UUID, input: Input,
                     token: AnisetteConsentToken, broker: SideSignTwoFactorBroker) async {
        do {
            try requireCurrent(operation, flow: flow, token: token)
            let descriptor = provider.descriptor
            let headers: AnisetteData
            do { headers = try await provider.freshHeaders() }
            catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                throw AnisetteConsentError.providerFailed
            }
            guard provider.descriptor == descriptor else { throw AnisetteConsentError.providerChanged }
            try requireCurrent(operation, flow: flow, token: token)
            let result: SideSignPreparedAccountSession
            switch input {
            case .password(let appleID, let password, let version):
                result = try await adapter.authenticate(appleID: appleID, password: password, freshAnisetteData: headers,
                                                        xcodeVersion: version, twoFactor: broker,
                                                        onTwoFactor: { try await self.beginChallenge(operation: operation, flow: flow, token: token) })
            case .resume(let candidate):
                result = try await adapter.revalidate(encodedSession: candidate.encodedSession, freshAnisetteData: headers)
            }
            try requireCurrent(operation, flow: flow, token: token)
            let teams = try result.teams.map { team -> AppleAccountSessionMetadata.Team in
                let membership: AppleAccountSessionMetadata.Team.Membership
                switch team.category {
                case .free: membership = .free
                case .individual, .organization: membership = .developerProgramUnverified
                case .unknown: throw Failure.unsupportedTeam
                @unknown default: throw Failure.unsupportedTeam
                }
                return .init(identifier: team.identifier, membership: membership)
            }
            let accepted: Bool
            switch input {
            case .password:
                accepted = try await coordinator.receiveAuthenticatedSession(operation: operation,
                    encodedSession: result.encodedSession, teams: teams, expiresAt: result.expiresAt, now: clock())
            case .resume(let candidate):
                accepted = try await coordinator.receiveRevalidatedSession(operation: operation,
                    reference: candidate.reference, teams: teams, expiresAt: result.expiresAt, now: clock())
            }
            // The coordinator is authoritative across this actor hop. Operation
            // guards prevent stale writes. Never delete an already accepted record
            // just because a bridge callback became stale or its task was cancelled.
            if generation == flow, active?.operation == operation {
                active?.deadline.cancel()
                active = nil
                observer?.yield(accepted ? .awaitingTeamSelection(operation) : .cancelled(operation))
            }
            await broker.cancel()
        } catch {
            _ = await coordinator.failAuthentication(operation: operation)
            await broker.cancel()
            guard generation == flow, active?.operation == operation else { return }
            active?.deadline.cancel()
            active = nil
            if error is CancellationError || Task.isCancelled { observer?.yield(.cancelled(operation)) }
            else { observer?.yield(.failed(operation, safeFailure(error))) }
        }
    }

    private func requireCurrent(_ operation: UUID, flow: UUID, token: AnisetteConsentToken) throws {
        try Task.checkCancellation()
        guard generation == flow, active?.operation == operation else { throw CancellationError() }
        try consent.require(token, provider: provider.descriptor, now: clock())
    }

    private func expireConsent(operation: UUID, flow: UUID) async {
        guard generation == flow, active?.operation == operation else { return }
        consent.revoke()
        await certificateStatusConsent.revoke()
        _ = await cancelAuthentication(operation: operation)
    }

    private func beginChallenge(operation: UUID, flow: UUID, token: AnisetteConsentToken) async throws {
        try requireCurrent(operation, flow: flow, token: token)
        guard await coordinator.requireTwoFactor(operation: operation) else { throw CancellationError() }
        try requireCurrent(operation, flow: flow, token: token)
    }

    /// Both the bridge operation and broker challenge must match. Reject replies
    /// while a retry/sign-out is crossing the coordinator boundary.
    func submitTwoFactor(_ response: TwoFactorResponse, operation: UUID, challengeID: UUID) async -> Bool {
        guard !setupBusy, maintenanceCount == 0, provisioningTask == nil, identityTask == nil, identityDiscardTask == nil, certificateTask == nil, registrationTask == nil, profileTask == nil, certificateStatusTask == nil, let current = active, current.operation == operation else { return false }
        do { try consent.require(current.consent, provider: provider.descriptor, now: clock()) }
        catch { _ = await cancelAuthentication(operation: operation); return false }
        guard await coordinator.requireTwoFactor(operation: operation) else { return false }
        guard active?.operation == operation, maintenanceCount == 0 else { return false }
        return await current.broker.submit(response, operation: operation, challengeID: challengeID)
    }

    @discardableResult
    func cancelAuthentication(operation: UUID) async -> Bool {
        guard let current = active, current.operation == operation else { return false }
        maintenanceCount += 1
        defer { maintenanceCount -= 1 }
        generation = UUID()
        active = nil
        current.task.cancel()
        current.deadline.cancel()
        await current.broker.cancel()
        let invalidated = await coordinator.failAuthentication(operation: operation)
        // Acceptance may have won the coordinator race. Do not report a durable
        // account as cancelled/signed out or delete it via stale-task cleanup.
        observer?.yield(invalidated ? .cancelled(operation) : .stateChanged(operation))
        return invalidated
    }

    func revokeAnisetteConsent() async {
        generation = UUID()
        provisioningTask?.cancel()
        identityTask?.cancel()
        identityDiscardTask?.cancel()
        certificateTask?.cancel()
        registrationTask?.cancel()
        revokeProfileCreationApproval()
        certificateStatusEpoch = UUID()
        certificateStatusTask?.cancel()
        registrationApproval = nil
        registrationEpoch = UUID()
        certificateApproval = nil
        certificateApprovalEpoch = UUID()
        consent.revoke()
        await certificateStatusConsent.revoke()
        if let operation = active?.operation { _ = await cancelAuthentication(operation: operation) }
    }

    func signOut() async throws {
        guard !closed else { throw Failure.closed }
        provisioningTask?.cancel()
        identityTask?.cancel()
        identityDiscardTask?.cancel()
        certificateTask?.cancel()
        registrationTask?.cancel()
        revokeProfileCreationApproval()
        certificateStatusEpoch = UUID()
        certificateStatusTask?.cancel()
        registrationApproval = nil
        registrationEpoch = UUID()
        certificateApproval = nil
        certificateApprovalEpoch = UUID()
        maintenanceCount += 1
        defer { maintenanceCount -= 1 }
        generation = UUID()
        consent.revoke()
        await certificateStatusConsent.revoke()
        let current = active
        active = nil
        current?.task.cancel()
        current?.deadline.cancel()
        await current?.broker.cancel()
        do { try await coordinator.signOut() }
        catch { throw Failure.secureStorageBlocked }
    }

    func retryPendingDeletions() async throws {
        guard !closed else { throw Failure.closed }
        maintenanceCount += 1
        defer { maintenanceCount -= 1 }
        do { try await coordinator.retryPendingDeletions() }
        catch { throw Failure.secureStorageBlocked }
    }

    func selectTeam(identifier: String, operation: UUID) async throws -> Bool {
        guard !closed else { throw Failure.closed }
        guard !setupBusy, maintenanceCount == 0, provisioningTask == nil, identityTask == nil, identityDiscardTask == nil, certificateTask == nil, registrationTask == nil, profileTask == nil, certificateStatusTask == nil else { throw Failure.flowBusy }
        return try await coordinator.selectTeam(identifier: identifier, operation: operation, now: clock())
    }

    func snapshot() async -> AppleAccountSessionCoordinator<Sessions, Journal>.Snapshot { await coordinator.snapshot() }

    private func safeFailure(_ error: Error) -> Failure {
        if let safe = error as? Failure { return safe }
        if let gate = error as? AnisetteConsentError {
            switch gate {
            case .providerChanged: return .providerChanged
            case .providerFailed: return .providerFailed
            default: return .consentRequired
            }
        }
        if let codec = error as? SideSignSessionCodecError, codec == .expired || codec == .unknownExpiry { return .sessionExpired }
        if error is AppleAccountSessionRepositoryError || error is AppleAccountSessionCoordinatorError { return .secureStorageBlocked }
        return .authenticationFailed
    }
}


extension SideSignAccountBridge where Portal: SideSignProvisioningPortal {
    /// No portal mutations. The retained worker also retains this bridge's
    /// namespace lease if cancellation is ignored by an underlying request.
    func provisioningPreflight(contextID: UUID, request: NativeAccountProvisioningRequest,
                               token: AnisetteConsentToken) async throws -> NativeAccountProvisioningPlan {
        guard !closed else { throw Failure.closed }
        guard !setupBusy, maintenanceCount == 0, active == nil, provisioningTask == nil, identityTask == nil, identityDiscardTask == nil, certificateTask == nil, registrationTask == nil, profileTask == nil, certificateStatusTask == nil else { throw Failure.flowBusy }
        try consent.require(token, provider: provider.descriptor, now: clock())
        let flow = generation
        let worker = Task { try await self.runProvisioningPreflight(contextID: contextID, request: request, token: token, flow: flow) }
        provisioningTask = worker
        defer { provisioningTask = nil }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
    }

    private func requireProvisioningCurrent(contextID: UUID, token: AnisetteConsentToken, flow: UUID) async throws {
        try Task.checkCancellation()
        guard !closed, generation == flow, maintenanceCount == 0,
              await coordinator.acceptsProvisioningResult(contextID: contextID, now: clock()) else {
            throw NativeProvisioningError.contextChanged
        }
        // Recheck after the coordinator actor hop, not just before suspension.
        try Task.checkCancellation()
        guard !closed, generation == flow, maintenanceCount == 0 else { throw NativeProvisioningError.contextChanged }
        do { try consent.require(token, provider: provider.descriptor, now: clock()) }
        catch { throw NativeProvisioningError.consentRequired }
    }

    private func runProvisioningPreflight(contextID: UUID, request: NativeAccountProvisioningRequest,
                                         token: AnisetteConsentToken, flow: UUID) async throws -> NativeAccountProvisioningPlan {
        do {
            try await requireProvisioningCurrent(contextID: contextID, token: token, flow: flow)
            let candidate: (context: AppleAccountAuthenticationState.Context, encodedSession: Data)
            do {
                guard let value = try await coordinator.provisioningCandidate(contextID: contextID, now: clock()) else {
                    throw NativeProvisioningError.contextChanged
                }
                candidate = value
            } catch let safe as NativeProvisioningError { throw safe }
            catch { throw NativeProvisioningError.storageUnavailable }
            try await requireProvisioningCurrent(contextID: contextID, token: token, flow: flow)
            let headers: AnisetteData
            do { headers = try await provider.freshHeaders() }
            catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                throw NativeProvisioningError.providerFailed
            }
            try await requireProvisioningCurrent(contextID: contextID, token: token, flow: flow)
            let inventory = try await SideSignProvisioningAdapter(portal: adapter.provisioningPortal).inventory(
                encodedSession: candidate.encodedSession, headers: headers, teamIdentifier: candidate.context.team.identifier,
                request: request, now: clock(), checkCurrent: {
                    try await self.requireProvisioningCurrent(contextID: contextID, token: token, flow: flow)
                })
            try await requireProvisioningCurrent(contextID: contextID, token: token, flow: flow)
            guard let expiry = candidate.context.session.expiresAt else { throw NativeProvisioningError.contextChanged }
            return try inventory.plan(request: request, contextID: contextID, teamIdentifier: candidate.context.team.identifier,
                                      now: clock(), sessionExpiry: expiry)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if let safe = error as? NativeProvisioningError { throw safe }
            throw NativeProvisioningError.requestFailed
        }
    }
}


extension SideSignAccountBridge {
    /// Explicit local key preparation only: no anisette/Apple request and no
    /// private-key/CSR export. The worker retains the bridge's namespace lease.
    func prepareSigningIdentity(contextID: UUID) async throws -> NativeSigningIdentityTicket {
        guard !closed else { throw Failure.closed }
        guard !setupBusy, maintenanceCount == 0, active == nil,
              provisioningTask == nil, identityTask == nil, identityDiscardTask == nil, certificateTask == nil, registrationTask == nil, profileTask == nil, certificateStatusTask == nil else { throw NativeSigningIdentityError.busy }
        let flow = generation
        let worker = Task {
            let owner = try await self.identityOwner(contextID: contextID, flow: flow)
            let ticket = try await self.signingIdentities.prepare(owner: owner, now: self.clock())
            // Losing the context after persistence never erases the durable key.
            try await self.requireIdentityContext(contextID: contextID, flow: flow)
            return ticket
        }
        identityTask = worker
        defer { identityTask = nil }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    func discardPreparedSigningIdentity(contextID: UUID, identityID: UUID) async throws {
        guard !closed else { throw Failure.closed }
        guard !setupBusy, maintenanceCount == 0, active == nil,
              provisioningTask == nil, identityTask == nil, identityDiscardTask == nil, certificateTask == nil, registrationTask == nil, profileTask == nil, certificateStatusTask == nil else { throw NativeSigningIdentityError.busy }
        let flow = generation
        let worker = Task {
            let owner = try await self.identityOwner(contextID: contextID, flow: flow)
            try await self.signingIdentities.discardPrepared(owner: owner, identityID: identityID)
        }
        identityDiscardTask = worker
        defer { identityDiscardTask = nil }
        try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    private func requireIdentityContext(contextID: UUID, flow: UUID) async throws {
        try Task.checkCancellation()
        guard !closed, generation == flow, maintenanceCount == 0,
              await coordinator.acceptsProvisioningResult(contextID: contextID, now: clock()) else {
            throw NativeSigningIdentityError.contextChanged
        }
        try Task.checkCancellation()
        guard !closed, generation == flow, maintenanceCount == 0 else { throw NativeSigningIdentityError.contextChanged }
    }

    private func identityOwner(contextID: UUID, flow: UUID) async throws -> NativeSigningIdentityOwner {
        try await requireIdentityContext(contextID: contextID, flow: flow)
        do {
            guard let candidate = try await coordinator.provisioningCandidate(contextID: contextID, now: clock()) else {
                throw NativeSigningIdentityError.contextChanged
            }
            try await requireIdentityContext(contextID: contextID, flow: flow)
            return try SideSignSessionCodec.identityOwner(candidate.encodedSession,
                teamIdentifier: candidate.context.team.identifier, now: clock())
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if let safe = error as? NativeSigningIdentityError { throw safe }
            throw NativeSigningIdentityError.storageUnavailable
        }
    }
}


extension SideSignAccountBridge {
    func revokeCertificateCreationApproval() {
        certificateApprovalEpoch = UUID()
        certificateApproval = nil
        certificateTask?.cancel()
    }

    func recordExplicitCertificateCreationApproval(contextID: UUID, identityID: UUID,
                                                   lifetime: TimeInterval = 120) async throws -> NativeCertificateCreationApproval {
        guard !closed else { throw Failure.closed }
        guard lifetime.isFinite, lifetime > 0, lifetime <= 120 else { throw NativeSigningIdentityError.creationApprovalRequired }
        let flow = generation
        let epoch = certificateApprovalEpoch
        let owner = try await identityOwner(contextID: contextID, flow: flow)
        let ticket = try await signingIdentities.ticket(owner: owner, identityID: identityID)
        try await requireIdentityContext(contextID: contextID, flow: flow)
        guard !setupBusy, maintenanceCount == 0, active == nil, provisioningTask == nil,
              identityTask == nil, identityDiscardTask == nil, certificateTask == nil, registrationTask == nil, profileTask == nil, certificateStatusTask == nil else { throw NativeSigningIdentityError.busy }
        guard ticket.phase == .prepared else { throw NativeSigningIdentityError.reconciliationRequired }
        guard epoch == certificateApprovalEpoch else { throw NativeSigningIdentityError.creationApprovalRequired }
        let now = clock()
        guard now.timeIntervalSince1970.isFinite else { throw NativeSigningIdentityError.creationApprovalRequired }
        let approval = NativeCertificateCreationApproval(id: UUID(), contextID: contextID, identityID: identityID,
                                                         flow: flow, epoch: epoch, expiresAt: now.addingTimeInterval(lifetime))
        certificateApproval = approval
        return approval
    }
}

extension SideSignAccountBridge where Portal: SideSignPreparedCSRPortal {
    func createDevelopmentSigningCertificate(contextID: UUID, identityID: UUID,
                                             approval: NativeCertificateCreationApproval,
                                             consent token: AnisetteConsentToken) async throws -> NativeSigningIdentityTicket {
        try requireCreationApproval(approval, contextID: contextID, identityID: identityID, flow: generation)
        guard certificateApproval == approval else { throw NativeSigningIdentityError.creationApprovalRequired }
        guard !closed else { throw Failure.closed }
        guard !setupBusy, maintenanceCount == 0, active == nil, provisioningTask == nil,
              identityTask == nil, identityDiscardTask == nil, certificateTask == nil, registrationTask == nil, profileTask == nil, certificateStatusTask == nil else { throw NativeSigningIdentityError.busy }
        try consent.require(token, provider: provider.descriptor, now: clock())
        certificateApproval = nil // single-use even if authorization/setup fails
        return try await certificateWork(contextID: contextID, identityID: identityID, token: token, approval: approval)
    }

    func reconcileUncertainSigningCertificate(contextID: UUID, identityID: UUID,
                                              consent token: AnisetteConsentToken) async throws -> NativeSigningIdentityTicket {
        guard !closed else { throw Failure.closed }
        guard !setupBusy, maintenanceCount == 0, active == nil, provisioningTask == nil,
              identityTask == nil, identityDiscardTask == nil, certificateTask == nil, registrationTask == nil, profileTask == nil, certificateStatusTask == nil else { throw NativeSigningIdentityError.busy }
        try consent.require(token, provider: provider.descriptor, now: clock())
        return try await certificateWork(contextID: contextID, identityID: identityID, token: token, approval: nil)
    }

    private func certificateWork(contextID: UUID, identityID: UUID, token: AnisetteConsentToken,
                                 approval: NativeCertificateCreationApproval?) async throws -> NativeSigningIdentityTicket {
        let flow = generation
        let worker = Task {
            try await self.runCertificateWork(contextID: contextID, identityID: identityID, token: token, approval: approval, flow: flow)
        }
        certificateTask = worker
        let expiry = min(token.expiresAt, approval?.expiresAt ?? token.expiresAt)
        let seconds = max(0, min(900, expiry.timeIntervalSince(clock())))
        let deadline = Task {
            do { try await Task.sleep(nanoseconds: seconds.isFinite ? UInt64(seconds * 1_000_000_000) : 0) }
            catch { return }
            worker.cancel()
        }
        defer { deadline.cancel(); certificateTask = nil }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    private func requireCreationApproval(_ approval: NativeCertificateCreationApproval, contextID: UUID,
                                         identityID: UUID, flow: UUID) throws {
        guard approval.contextID == contextID, approval.identityID == identityID,
              approval.flow == flow, approval.epoch == certificateApprovalEpoch, approval.expiresAt > clock() else { throw NativeSigningIdentityError.creationApprovalRequired }
    }

    private func requireCertificateCurrent(contextID: UUID, identityID: UUID, token: AnisetteConsentToken,
                                           approval: NativeCertificateCreationApproval?, flow: UUID) async throws {
        try await requireProvisioningCurrent(contextID: contextID, token: token, flow: flow)
        if let approval { try requireCreationApproval(approval, contextID: contextID, identityID: identityID, flow: flow) }
    }

    private func runCertificateWork(contextID: UUID, identityID: UUID, token: AnisetteConsentToken,
                                     approval: NativeCertificateCreationApproval?, flow: UUID) async throws -> NativeSigningIdentityTicket {
        do {
            let check: @Sendable () async throws -> Void = {
                try await self.requireCertificateCurrent(contextID: contextID, identityID: identityID, token: token, approval: approval, flow: flow)
            }
            try await check()
            let owner = try await identityOwner(contextID: contextID, flow: flow)
            let ticket = try await signingIdentities.ticket(owner: owner, identityID: identityID)
            guard ticket.phase == (approval == nil ? .submissionUncertain : .prepared) else {
                throw NativeSigningIdentityError.reconciliationRequired
            }
            let candidate: (context: AppleAccountAuthenticationState.Context, encodedSession: Data)
            do {
                guard let value = try await coordinator.provisioningCandidate(contextID: contextID, now: clock()) else {
                    throw NativeSigningIdentityError.contextChanged
                }
                candidate = value
            } catch let safe as NativeSigningIdentityError { throw safe }
            catch { throw NativeSigningIdentityError.storageUnavailable }
            try await check()
            let headers: AnisetteData
            do { headers = try await provider.freshHeaders() }
            catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                throw NativeProvisioningError.providerFailed
            }
            try await check()
            let certificateAdapter = SideSignCertificateAdapter(portal: adapter.provisioningPortal)
            let authorized = try await certificateAdapter.authorize(encodedSession: candidate.encodedSession, headers: headers,
                teamIdentifier: owner.teamIdentifier, now: clock(), checkCurrent: check)
            try await check()
            if approval != nil {
                // This atomic intent MUST succeed before the only possible send.
                let submission = try await signingIdentities.beginSubmission(owner: owner, identityID: identityID)
                try await check() // expiry/cancellation here leaves uncertain, never sends
                let receipt = try await adapter.provisioningPortal.submitPreparedDevelopmentCSR(submission,
                    team: authorized.team, session: authorized.session)
                try await check()
                if let receipt {
                    let recorded = try await signingIdentities.recordCertificate(owner: owner, identityID: identityID,
                        certificateDER: receipt.certificateDER, certificateIdentifier: receipt.identifier, now: clock())
                    try await check()
                    return recorded
                }
            }
            // Read-only reconciliation, including success replies lacking direct
            // certificate bytes. There is NO call back to submission on this path.
            let observations = try await certificateAdapter.observations(team: authorized.team, session: authorized.session, checkCurrent: check)
            try await check()
            let recorded = try await signingIdentities.reconcileUncertain(owner: owner, identityID: identityID,
                certificates: observations, now: clock())
            try await check()
            return recorded
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if let safe = error as? NativeSigningIdentityError { throw safe }
            if let safe = error as? NativeProvisioningError { throw safe }
            throw NativeSigningIdentityError.certificateRequestFailed
        }
    }
}


extension SideSignAccountBridge {
    func revokeRegistrationApproval() {
        registrationEpoch = UUID()
        registrationApproval = nil
        registrationTask?.cancel()
    }

    func recordExplicitRegistrationApproval(contextID: UUID, subject: NativeRegistrationSubject,
                                            lifetime: TimeInterval = 120) async throws -> NativeAccountRegistrationApproval {
        guard !closed else { throw Failure.closed }
        guard !setupBusy, maintenanceCount == 0, active == nil, provisioningTask == nil, identityTask == nil,
              identityDiscardTask == nil, certificateTask == nil, registrationTask == nil, profileTask == nil, certificateStatusTask == nil else { throw NativeRegistrationError.busy }
        guard lifetime.isFinite, lifetime > 0, lifetime <= 120 else { throw NativeRegistrationError.approvalRequired }
        setupBusy = true
        defer { setupBusy = false }
        let flow = generation; let epoch = registrationEpoch
        let owner = try await identityOwner(contextID: contextID, flow: flow)
        try await requireIdentityContext(contextID: contextID, flow: flow)
        guard epoch == registrationEpoch else { throw NativeRegistrationError.approvalRequired }
        if let existing = try registrationStore.read(owner: owner, subject: subject) {
            try existing.validate(owner: owner, subject: subject)
            throw NativeRegistrationError.reconciliationRequired
        }
        let now = clock()
        guard now.timeIntervalSince1970.isFinite else { throw NativeRegistrationError.approvalRequired }
        let grant = NativeAccountRegistrationApproval(id: UUID(), contextID: contextID, ownerDigest: owner.digest,
            subjectDigest: subject.approvalDigest, flow: flow, epoch: epoch, expiresAt: now.addingTimeInterval(lifetime))
        registrationApproval = grant
        return grant
    }
}

extension SideSignAccountBridge where Portal: SideSignRegistrationTransport {
    func registerAccountResource(contextID: UUID, subject: NativeRegistrationSubject,
                                 approval grant: NativeAccountRegistrationApproval,
                                 consent token: AnisetteConsentToken) async throws -> NativeRegistrationResult {
        guard registrationApproval == grant else { throw NativeRegistrationError.approvalRequired }
        try requireRegistrationApproval(grant, contextID: contextID, subject: subject, flow: generation, epoch: registrationEpoch)
        try requireRegistrationSlot(token: token)
        registrationApproval = nil // consume before any asynchronous setup
        return try await registrationWork(contextID: contextID, subject: subject, grant: grant, token: token)
    }

    func reconcileAccountRegistration(contextID: UUID, subject: NativeRegistrationSubject,
                                      consent token: AnisetteConsentToken) async throws -> NativeRegistrationResult {
        try requireRegistrationSlot(token: token)
        return try await registrationWork(contextID: contextID, subject: subject, grant: nil, token: token)
    }

    private func requireRegistrationSlot(token: AnisetteConsentToken) throws {
        guard !closed else { throw Failure.closed }
        guard !setupBusy, maintenanceCount == 0, active == nil, provisioningTask == nil, identityTask == nil,
              identityDiscardTask == nil, certificateTask == nil, registrationTask == nil, profileTask == nil, certificateStatusTask == nil else { throw NativeRegistrationError.busy }
        try consent.require(token, provider: provider.descriptor, now: clock())
    }

    private func requireRegistrationApproval(_ grant: NativeAccountRegistrationApproval, contextID: UUID,
                                             subject: NativeRegistrationSubject, flow: UUID, epoch: UUID) throws {
        guard grant.contextID == contextID, grant.subjectDigest == subject.approvalDigest,
              grant.flow == flow, grant.epoch == epoch, grant.expiresAt > clock() else { throw NativeRegistrationError.approvalRequired }
    }

    private func requireRegistrationCurrent(contextID: UUID, subject: NativeRegistrationSubject,
                                            grant: NativeAccountRegistrationApproval?, token: AnisetteConsentToken,
                                            flow: UUID, epoch: UUID) async throws {
        try await requireProvisioningCurrent(contextID: contextID, token: token, flow: flow)
        guard registrationEpoch == epoch else { throw NativeRegistrationError.approvalRequired }
        if let grant { try requireRegistrationApproval(grant, contextID: contextID, subject: subject, flow: flow, epoch: epoch) }
    }

    private func registrationWork(contextID: UUID, subject: NativeRegistrationSubject,
                                  grant: NativeAccountRegistrationApproval?, token: AnisetteConsentToken) async throws -> NativeRegistrationResult {
        let flow = generation; let epoch = registrationEpoch
        let worker = Task { try await self.runRegistration(contextID: contextID, subject: subject, grant: grant, token: token, flow: flow, epoch: epoch) }
        registrationTask = worker
        let expiry = min(token.expiresAt, grant?.expiresAt ?? token.expiresAt)
        let seconds = max(0, min(900, expiry.timeIntervalSince(clock())))
        let timer = Task {
            do { try await Task.sleep(nanoseconds: seconds.isFinite ? UInt64(seconds * 1_000_000_000) : 0) }
            catch { return }
            worker.cancel()
        }
        defer { timer.cancel(); registrationTask = nil }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    private func runRegistration(contextID: UUID, subject: NativeRegistrationSubject,
                                 grant: NativeAccountRegistrationApproval?, token: AnisetteConsentToken,
                                 flow: UUID, epoch: UUID) async throws -> NativeRegistrationResult {
        let check: @Sendable () async throws -> Void = {
            try await self.requireRegistrationCurrent(contextID: contextID, subject: subject, grant: grant, token: token, flow: flow, epoch: epoch)
        }
        try await check()
        guard let lifetime else { throw NativeRegistrationError.invalidRequest }
        let owner = try await identityOwner(contextID: contextID, flow: flow)
        if let grant { guard grant.ownerDigest == owner.digest else { throw NativeRegistrationError.approvalRequired } }
        guard let candidate = try await coordinator.provisioningCandidate(contextID: contextID, now: clock()),
              let sessionExpiry = candidate.context.session.expiresAt else { throw NativeProvisioningError.contextChanged }
        try await check()
        let authorityExpiry = min(token.expiresAt, sessionExpiry)
        let provider = self.provider
        let bound = try SideSignBoundRegistrationPortal(portal: adapter.provisioningPortal, owner: owner, contextID: contextID,
            encodedSession: candidate.encodedSession, authorityExpiresAt: authorityExpiry, lifetime: lifetime,
            freshHeaders: {
                try await check()
                let headers = try await provider.freshHeaders()
                try await check()
                return headers
            }, checkCurrent: check, clock: clock)
        // Per-operation, never cached on the bridge: bound callbacks retain this
        // actor only until actual worker retirement, not through a service cycle.
        let executor = NativeRegistrationExecutor(store: registrationStore, portal: bound, clock: clock)
        let result: NativeRegistrationResult
        if let grant {
            let remaining = grant.expiresAt.timeIntervalSince(clock())
            guard remaining.isFinite, remaining > 0 else { throw NativeRegistrationError.approvalRequired }
            // Internal delegation of the consumed user approval. Remaining life
            // only; never extend/renew user authority or infer it from consent.
            let delegated = try await executor.approve(owner: owner, contextID: contextID, subject: subject, lifetime: min(120, remaining))
            try await check()
            result = try await executor.execute(owner: owner, contextID: contextID, subject: subject,
                approval: delegated, authorityExpiresAt: min(authorityExpiry, grant.expiresAt), checkCurrent: check)
        } else {
            result = try await executor.reconcile(owner: owner, contextID: contextID, subject: subject,
                authorityExpiresAt: authorityExpiry, checkCurrent: check)
        }
        try await check()
        return result
    }
}

extension SideSignAccountBridge {
    func revokeProfileCreationApproval() {
        profileEpoch = UUID(); profileApproval = nil; profileTask?.cancel()
    }

    func recordExplicitProfileCreationApproval(contextID: UUID, target: NativeAccountProfileTarget,
                                               lifetime: TimeInterval = 120) async throws -> NativeAccountProfileApproval {
        guard !closed else { throw Failure.closed }
        try profileValidator.requireCMSVerification() // default blocks before store/context/crypto I/O
        guard !setupBusy, maintenanceCount == 0, active == nil, provisioningTask == nil, identityTask == nil,
              identityDiscardTask == nil, certificateTask == nil, registrationTask == nil, profileTask == nil, certificateStatusTask == nil else { throw NativeProfileCreationError.busy }
        guard target.selectedProfileUUID == nil, lifetime.isFinite, lifetime > 0, lifetime <= 120 else { throw NativeProfileCreationError.approvalRequired }
        setupBusy = true
        defer { setupBusy = false }
        let flow = generation; let epoch = profileEpoch
        let owner = try await identityOwner(contextID: contextID, flow: flow)
        let request = try await makeProfileRequest(owner: owner, target: target)
        try await requireIdentityContext(contextID: contextID, flow: flow)
        try Task.checkCancellation()
        guard epoch == profileEpoch else { throw NativeProfileCreationError.approvalRequired }
        if let existing = try profileStore.read(owner: owner, request: request) {
            try existing.validate(owner: owner, request: request)
            throw NativeProfileCreationError.reconciliationRequired
        }
        let now = clock()
        guard now.timeIntervalSince1970.isFinite else { throw NativeProfileCreationError.approvalRequired }
        let grant = NativeAccountProfileApproval(id: UUID(), contextID: contextID, ownerDigest: owner.digest,
            targetDigest: target.approvalDigest, requestDigest: request.approvalDigest,
            flow: flow, epoch: epoch, expiresAt: now.addingTimeInterval(lifetime))
        profileApproval = grant
        return grant
    }

    private func makeProfileRequest(owner: NativeSigningIdentityOwner, target: NativeAccountProfileTarget) async throws -> NativeProfileCreationRequest {
        let owned = try await signingIdentities.ownedProfileIdentity(owner: owner, identityID: target.identityID,
            bundleIdentifier: target.bundleIdentifier, deviceIdentifier: target.deviceIdentifier, now: clock())
        let validation = try NativeProfileValidationRequest(teamIdentifier: owner.teamIdentifier,
            bundleIdentifier: target.bundleIdentifier, deviceIdentifier: target.deviceIdentifier,
            certificateDER: owned.validation.certificateDER, expectedUUID: target.selectedProfileUUID)
        let request = try NativeProfileCreationRequest(identityID: target.identityID, validation: validation,
            appID: target.appID, deviceID: target.deviceID, certificateID: owned.certificateIdentifier)
        try NativeProfileResourcePolicy.requireOwned(owned, request: request)
        return request
    }
}

extension SideSignAccountBridge where Portal: SideSignProfileTransport {
    func createAccountProvisioningProfile(contextID: UUID, target: NativeAccountProfileTarget,
                                          approval grant: NativeAccountProfileApproval,
                                          consent token: AnisetteConsentToken) async throws -> NativeAccountProfileResult {
        guard profileApproval == grant else { throw NativeProfileCreationError.approvalRequired }
        try requireProfileApproval(grant, contextID: contextID, target: target, flow: generation, epoch: profileEpoch)
        try requireProfileSlot(token: token)
        profileApproval = nil // single-use before asynchronous setup
        return try await profileWork(contextID: contextID, target: target, grant: grant, token: token)
    }

    func reconcileAccountProvisioningProfile(contextID: UUID, target: NativeAccountProfileTarget,
                                             consent token: AnisetteConsentToken) async throws -> NativeAccountProfileResult {
        try requireProfileSlot(token: token)
        return try await profileWork(contextID: contextID, target: target, grant: nil, token: token)
    }

    /// Read-only download of an existing profile by UUID. Session, team and
    /// context currency are revalidated inside the bridge, exactly as for
    /// provisioning preflight; nothing is created or renewed here.
    func downloadProvisioningProfile(contextID: UUID, profileUUID: UUID,
                                     consent token: AnisetteConsentToken) async throws -> Data {
        guard !closed else { throw Failure.closed }
        guard !setupBusy, maintenanceCount == 0, active == nil, provisioningTask == nil, identityTask == nil,
              identityDiscardTask == nil, certificateTask == nil, registrationTask == nil, profileTask == nil,
              certificateStatusTask == nil else { throw Failure.flowBusy }
        try consent.require(token, provider: provider.descriptor, now: clock())
        let flow = generation
        try await requireProvisioningCurrent(contextID: contextID, token: token, flow: flow)
        guard let candidate = try await coordinator.provisioningCandidate(contextID: contextID, now: clock()) else {
            throw NativeProvisioningError.contextChanged
        }
        try await requireProvisioningCurrent(contextID: contextID, token: token, flow: flow)
        let headers: AnisetteData
        do { headers = try await provider.freshHeaders() }
        catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw NativeProvisioningError.providerFailed
        }
        try await requireProvisioningCurrent(contextID: contextID, token: token, flow: flow)
        let data = try await adapter.provisioningPortal.downloadProvisioningProfile(
            encodedSession: candidate.encodedSession, headers: headers,
            teamIdentifier: candidate.context.team.identifier, profileUUID: profileUUID, now: clock())
        try await requireProvisioningCurrent(contextID: contextID, token: token, flow: flow)
        return data
    }

    private func requireProfileSlot(token: AnisetteConsentToken) throws {
        guard !closed else { throw Failure.closed }
        try profileValidator.requireCMSVerification()
        guard !setupBusy, maintenanceCount == 0, active == nil, provisioningTask == nil, identityTask == nil,
              identityDiscardTask == nil, certificateTask == nil, registrationTask == nil, profileTask == nil, certificateStatusTask == nil else { throw NativeProfileCreationError.busy }
        try consent.require(token, provider: provider.descriptor, now: clock())
    }

    private func requireProfileApproval(_ grant: NativeAccountProfileApproval, contextID: UUID,
                                        target: NativeAccountProfileTarget, flow: UUID, epoch: UUID) throws {
        guard grant.contextID == contextID, grant.targetDigest == target.approvalDigest,
              grant.flow == flow, grant.epoch == epoch, grant.expiresAt > clock(), target.selectedProfileUUID == nil else { throw NativeProfileCreationError.approvalRequired }
    }

    private func requireProfileCurrent(contextID: UUID, target: NativeAccountProfileTarget,
                                       grant: NativeAccountProfileApproval?, token: AnisetteConsentToken,
                                       flow: UUID, epoch: UUID) async throws {
        try await requireProvisioningCurrent(contextID: contextID, token: token, flow: flow)
        guard profileEpoch == epoch else { throw NativeProfileCreationError.approvalRequired }
        if let grant { try requireProfileApproval(grant, contextID: contextID, target: target, flow: flow, epoch: epoch) }
    }

    private func profileWork(contextID: UUID, target: NativeAccountProfileTarget,
                             grant: NativeAccountProfileApproval?, token: AnisetteConsentToken) async throws -> NativeAccountProfileResult {
        let flow = generation; let epoch = profileEpoch
        let worker = Task { try await self.runProfile(contextID: contextID, target: target, grant: grant, token: token, flow: flow, epoch: epoch) }
        profileTask = worker
        let expiry = min(token.expiresAt, grant?.expiresAt ?? token.expiresAt)
        let seconds = max(0, min(900, expiry.timeIntervalSince(clock())))
        let timer = Task {
            do { try await Task.sleep(nanoseconds: seconds.isFinite ? UInt64(seconds * 1_000_000_000) : 0) }
            catch { return }
            worker.cancel()
        }
        // Cancelled/uncooperative work retains this busy slot and lease until
        // actual retirement. Caller cancellation never clears uncertain intent.
        defer { timer.cancel(); profileTask = nil }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    private func runProfile(contextID: UUID, target: NativeAccountProfileTarget,
                            grant: NativeAccountProfileApproval?, token: AnisetteConsentToken,
                            flow: UUID, epoch: UUID) async throws -> NativeAccountProfileResult {
        let check: @Sendable () async throws -> Void = {
            try await self.requireProfileCurrent(contextID: contextID, target: target, grant: grant, token: token, flow: flow, epoch: epoch)
        }
        try await check()
        guard let lifetime else { throw NativeProfileCreationError.invalidRequest }
        let owner = try await identityOwner(contextID: contextID, flow: flow)
        let request = try await makeProfileRequest(owner: owner, target: target)
        try await check()
        if let grant {
            guard grant.ownerDigest == owner.digest, grant.requestDigest == request.approvalDigest else { throw NativeProfileCreationError.approvalRequired }
        }
        guard let candidate = try await coordinator.provisioningCandidate(contextID: contextID, now: clock()),
              let sessionExpiry = candidate.context.session.expiresAt else { throw NativeProvisioningError.contextChanged }
        try await check()
        let authorityExpiry = min(sessionExpiry, min(token.expiresAt, grant?.expiresAt ?? token.expiresAt))
        let provider = self.provider; let identities = signingIdentities; let workerClock = self.clock
        let bound = try SideSignBoundProfilePortal(portal: adapter.provisioningPortal, owner: owner, contextID: contextID,
            request: request, encodedSession: candidate.encodedSession, authorityExpiresAt: authorityExpiry,
            lifetime: lifetime, validator: profileValidator, freshHeaders: {
                try await check()
                let headers = try await provider.freshHeaders()
                try await check()
                return headers
            }, ownedIdentity: {
                try await check()
                let owned = try await identities.ownedProfileIdentity(owner: owner, identityID: target.identityID,
                    bundleIdentifier: target.bundleIdentifier, deviceIdentifier: target.deviceIdentifier, now: workerClock())
                try await check()
                return owned
            }, checkCurrent: check, clock: workerClock)
        let executor = NativeProfileCreationExecutor(store: profileStore, portal: bound, validator: profileValidator, clock: workerClock)
        do {
            let result: NativeProfileCreationResult
            if let grant {
                let remaining = grant.expiresAt.timeIntervalSince(clock())
                guard remaining.isFinite, remaining > 0 else { throw NativeProfileCreationError.approvalRequired }
                let delegated = try await executor.approve(owner: owner, contextID: contextID, request: request, lifetime: min(120, remaining))
                try await check()
                result = try await executor.execute(owner: owner, contextID: contextID, request: request,
                    approval: delegated, authorityExpiresAt: authorityExpiry, checkCurrent: check)
            } else {
                result = try await executor.reconcile(owner: owner, contextID: contextID, request: request,
                    authorityExpiresAt: authorityExpiry, checkCurrent: check)
            }
            await bound.invalidate()
            try await check()
            return NativeAccountProfileResult(operationID: result.operationID, profileUUID: result.profile.constraints.uuid,
                expiresAt: result.profile.constraints.expiresAt)
        } catch {
            await bound.invalidate()
            throw error
        }
    }
}

extension SideSignAccountBridge {
    func recordExplicitCertificateStatusConsent(contextID: UUID, identityID: UUID,
                                                lifetime: TimeInterval = 120) async throws -> NativeCertificateStatusConsent {
        guard !closed else { throw Failure.closed }
        guard !setupBusy, maintenanceCount == 0, active == nil, provisioningTask == nil, identityTask == nil,
              identityDiscardTask == nil, certificateTask == nil, registrationTask == nil, profileTask == nil,
              certificateStatusTask == nil else { throw NativeCertificateStatusConsentError.busy }
        setupBusy = true
        defer { setupBusy = false }
        let flow = generation; let epoch = certificateStatusEpoch
        let owner = try await identityOwner(contextID: contextID, flow: flow)
        let owned = try await signingIdentities.ownedSigningCertificate(owner: owner, identityID: identityID, now: clock())
        try await requireIdentityContext(contextID: contextID, flow: flow)
        guard epoch == certificateStatusEpoch else { throw NativeCertificateStatusConsentError.consentRequired }
        let grant = try await certificateStatusConsent.recordExplicitConsent(owner: owner, contextID: contextID,
            identityID: identityID, certificate: owned.certificateDER, flow: flow, now: clock(), lifetime: lifetime)
        do {
            try await requireIdentityContext(contextID: contextID, flow: flow)
            guard epoch == certificateStatusEpoch else { throw NativeCertificateStatusConsentError.consentRequired }
        } catch { await certificateStatusConsent.revoke(); throw error }
        return grant
    }

    func revokeCertificateStatusConsent() async {
        certificateStatusEpoch = UUID()
        certificateStatusTask?.cancel()
        await certificateStatusConsent.revoke()
    }

    // MARK: - Key Export Consent

    func recordExplicitKeyExportConsent(contextID: UUID, identityID: UUID,
                                         lifetime: TimeInterval = 120) async throws -> NativeKeyExportConsent {
        guard !closed else { throw Failure.closed }
        guard !setupBusy, maintenanceCount == 0, active == nil, provisioningTask == nil, identityTask == nil,
              identityDiscardTask == nil, certificateTask == nil, registrationTask == nil, profileTask == nil,
              certificateStatusTask == nil else { throw NativeSigningIdentityError.busy }
        let flow = generation; let epoch = keyExportEpoch
        let owner = try await identityOwner(contextID: contextID, flow: flow)
        let owned = try await signingIdentities.ownedSigningCertificate(owner: owner, identityID: identityID, now: clock())
        try await requireIdentityContext(contextID: contextID, flow: flow)
        guard epoch == keyExportEpoch else { throw NativeSigningIdentityError.creationApprovalRequired }
        let grant = try await keyExportConsent.recordExplicitConsent(owner: owner, identityID: identityID, certificate: owned.certificateDER, flow: flow, now: clock(), lifetime: lifetime)
        do {
            try await requireIdentityContext(contextID: contextID, flow: flow)
            guard epoch == keyExportEpoch else { throw NativeSigningIdentityError.creationApprovalRequired }
        } catch { await keyExportConsent.revoke(); throw error }
        return grant
    }

    func revokeKeyExportConsent() async {
        keyExportEpoch = UUID()
        await keyExportConsent.revoke()
    }

    /// Read-only inventory of the durable profile journal rows owned by this
    /// context. The owner is derived inside the bridge from the current
    /// session candidate; callers never touch the profile store directly.
    func recordedProfileRecords(contextID: UUID) async throws -> [NativeProfileCreationRecord] {
        guard !closed else { throw Failure.closed }
        guard !setupBusy, maintenanceCount == 0, active == nil, provisioningTask == nil, identityTask == nil,
              identityDiscardTask == nil, certificateTask == nil, registrationTask == nil, profileTask == nil,
              certificateStatusTask == nil else { throw Failure.flowBusy }
        let flow = generation
        let owner = try await identityOwner(contextID: contextID, flow: flow)
        let records = try profileStore.listAllRecords(owner: owner)
        try await requireIdentityContext(contextID: contextID, flow: flow)
        return records
    }

    /// Owner-bound certificate and private-key material for one explicitly
    /// consented export. The caller must validate its consent token against
    /// the returned owner/certificate before using the key material.
    func keyExportMaterial(contextID: UUID, identityID: UUID) async throws
        -> (owner: NativeSigningIdentityOwner, owned: NativeOwnedSigningCertificate, privateKeyDER: Data) {
        guard !closed else { throw Failure.closed }
        guard !setupBusy, maintenanceCount == 0, active == nil, provisioningTask == nil, identityTask == nil,
              identityDiscardTask == nil, certificateTask == nil, registrationTask == nil, profileTask == nil,
              certificateStatusTask == nil else { throw NativeSigningIdentityError.busy }
        let flow = generation
        let owner = try await identityOwner(contextID: contextID, flow: flow)
        let owned = try await signingIdentities.ownedSigningCertificate(owner: owner, identityID: identityID, now: clock())
        let privateKeyDER = try await signingIdentities.privateKeyDER(owner: owner, identityID: identityID, now: clock())
        try await requireIdentityContext(contextID: contextID, flow: flow)
        return (owner, owned, privateKeyDER)
    }

    /// Offline positive cache unless a separate exact single-use status consent
    /// is supplied. Never submits a certificate/CSR/profile or changes quota.
    func evaluateSigningCertificateStatus(contextID: UUID, identityID: UUID,
                                           statusConsent grant: NativeCertificateStatusConsent? = nil) async throws -> NativeAccountCertificateStatus {
        guard !closed else { throw Failure.closed }
        guard !setupBusy, maintenanceCount == 0, active == nil, provisioningTask == nil, identityTask == nil,
              identityDiscardTask == nil, certificateTask == nil, registrationTask == nil, profileTask == nil,
              certificateStatusTask == nil else { throw NativeCertificateStatusConsentError.busy }
        let flow = generation; let epoch = certificateStatusEpoch
        let worker = Task { try await self.runCertificateStatus(contextID: contextID, identityID: identityID, grant: grant, flow: flow, epoch: epoch) }
        certificateStatusTask = worker
        let expiry = min(grant?.expiresAt ?? clock().addingTimeInterval(120), clock().addingTimeInterval(120))
        let seconds = max(0, min(120, expiry.timeIntervalSince(clock())))
        let timer = Task {
            do { try await Task.sleep(nanoseconds: seconds.isFinite ? UInt64(seconds * 1_000_000_000) : 0) }
            catch { return }
            worker.cancel()
        }
        defer { timer.cancel(); certificateStatusTask = nil }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    private func requireCertificateStatusCurrent(contextID: UUID, flow: UUID, epoch: UUID) async throws {
        try await requireIdentityContext(contextID: contextID, flow: flow)
        guard certificateStatusEpoch == epoch else { throw NativeCertificateStatusConsentError.consentRequired }
    }

    private func runCertificateStatus(contextID: UUID, identityID: UUID, grant: NativeCertificateStatusConsent?,
                                       flow: UUID, epoch: UUID) async throws -> NativeAccountCertificateStatus {
        let check: @Sendable () async throws -> Void = {
            try await self.requireCertificateStatusCurrent(contextID: contextID, flow: flow, epoch: epoch)
        }
        try await check()
        guard let lifetime else { throw NativeDevelopmentCertificateError.contextChanged }
        // Retain the namespace even while an uncancellable OS trust call retires.
        defer { withExtendedLifetime(lifetime) {} }
        let owner = try await identityOwner(contextID: contextID, flow: flow)
        let owned = try await signingIdentities.ownedSigningCertificate(owner: owner, identityID: identityID, now: clock())
        try await check()
        let authorization = grant.map { NativeCertificateStatusAuthorization(gate: certificateStatusConsent, consent: $0, flow: flow) }
        let result = try await NativeDevelopmentCertificateVerifier().evaluate(owner: owner, contextID: contextID,
            certificateDER: owned.certificateDER, issuerCertificates: NativeDevelopmentIssuerStore.certificates(),
            now: clock(), identityID: identityID, networkAuthorization: authorization, clock: clock, checkCurrent: check)
        try await check()
        let current = try await signingIdentities.ownedSigningCertificate(owner: owner, identityID: identityID, now: clock())
        try await check()
        guard current.certificateDER == owned.certificateDER, current.certificateIdentifier == owned.certificateIdentifier else { throw NativeSigningIdentityError.identityChanged }
        return NativeAccountCertificateStatus(result)
    }

}
