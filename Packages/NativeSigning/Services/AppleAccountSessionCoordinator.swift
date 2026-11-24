import Foundation

/// Insert is atomic/add-only; implementations must not write before throwing.
/// Synchronous storage is owned by this worker actor, not the UI executor.
protocol AppleAccountSessionStorage: Sendable {
    @discardableResult
    func insertSession(_ sessionData: Data, reference: UUID) throws -> UUID
    func deleteSession(reference: UUID) throws
}

enum AppleAccountSessionCoordinatorError: Error, Equatable {
    case cleanupRequired
    case invalidSessionMetadata
    case resumeRequired
    case authenticationInProgress
}

/// Sole owner of the durable persistence value and transient authentication state.
/// Storage runs synchronously on this worker actor: no actor await separates a
/// journaled commit from accepting metadata, so task callbacks cannot reenter that
/// boundary. Network/SDK work remains outside and must carry operation UUIDs.
/// No authentication UI or SDK/codec implementation is implied by this type.
actor AppleAccountSessionCoordinator<Sessions: AppleAccountRecoverableSessionStorage, Journal: AppleAccountResumeJournalStorage> {
    struct Snapshot: Equatable, Sendable {
        let phase: AppleAccountAuthenticationState.Phase
        let cleanupRequired: Bool
    }

    private var persistence: AppleAccountSessionPersistence<Sessions, Journal>
    private var state = AppleAccountAuthenticationState()
    private var cleanupRequired = false
    private var authenticationTask: Task<Void, Never>?
    private var revalidatingReference: UUID?

    init(sessions: Sessions, journal: Journal) {
        persistence = AppleAccountSessionPersistence(sessions: sessions, journal: journal)
    }

    func snapshot() -> Snapshot {
        Snapshot(phase: state.phase, cleanupRequired: cleanupRequired)
    }

    /// A saved candidate is not silently replaced by another login. The future
    /// adapter must revalidate it or obtain explicit user sign-out first.
    func beginAuthentication() throws -> UUID? {
        guard !cleanupRequired else { throw AppleAccountSessionCoordinatorError.cleanupRequired }
        guard state.credentialReference == nil else { return nil }
        guard try persistence.recoverCandidate() == nil else {
            throw AppleAccountSessionCoordinatorError.resumeRequired
        }
        guard let operation = state.beginAuthentication() else { return nil }
        cancelAuthenticationTask()
        revalidatingReference = nil
        return operation
    }

    /// Read-only access for the future SDK revalidation path. This never changes
    /// transient authentication state or treats a persisted team hint as consent.
    func recoverCandidate() throws -> AppleAccountSessionPersistence<Sessions, Journal>.ResumeCandidate? {
        guard !cleanupRequired else { throw AppleAccountSessionCoordinatorError.cleanupRequired }
        guard case .signedOut = state.phase else {
            throw AppleAccountSessionCoordinatorError.authenticationInProgress
        }
        return try persistence.recoverCandidate()
    }

    /// A saved reference is not accepted until the adapter revalidates its token,
    /// identity and teams. A saved team hint never selects a team automatically.
    func beginRevalidation() throws -> (operation: UUID, candidate: AppleAccountSessionPersistence<Sessions, Journal>.ResumeCandidate)? {
        guard !cleanupRequired else { throw AppleAccountSessionCoordinatorError.cleanupRequired }
        guard state.credentialReference == nil else { return nil }
        guard let candidate = try persistence.recoverCandidate(),
              let operation = state.beginAuthentication() else { return nil }
        cancelAuthenticationTask()
        revalidatingReference = candidate.reference
        return (operation, candidate)
    }

    @discardableResult
    func receiveRevalidatedSession(operation: UUID, reference: UUID,
                                   teams: [AppleAccountSessionMetadata.Team], expiresAt: Date, now: Date) throws -> Bool {
        guard isPending(operation), revalidatingReference == reference else { return false }
        guard !cleanupRequired else { throw AppleAccountSessionCoordinatorError.cleanupRequired }
        let metadata = AppleAccountSessionMetadata(credentialReference: reference, teams: teams, expiresAt: expiresAt)
        guard metadata.isValid(at: now) else { throw AppleAccountSessionCoordinatorError.invalidSessionMetadata }
        guard try persistence.recoverCandidate()?.reference == reference else {
            throw AppleAccountSessionRepositoryError.staleReference
        }
        state.receiveAuthenticatedSession(operation: operation, session: metadata, now: now)
        revalidatingReference = nil
        authenticationTask = nil
        return true
    }

    /// Register each SDK task (including a replacement 2FA task). A task that
    /// arrives after cancellation/retry/success is cancelled immediately.
    /// The SDK adapter must still validate callback UUIDs via this coordinator
    /// and resume/cancel its own suspended verification continuations. Cancelling
    /// a handle cannot force an uncooperative SDK operation to stop.
    @discardableResult
    func attachAuthenticationTask(_ task: Task<Void, Never>, operation: UUID) -> Bool {
        guard isPending(operation) else {
            task.cancel()
            return false
        }
        cancelAuthenticationTask()
        authenticationTask = task
        return true
    }

    @discardableResult
    func requireTwoFactor(operation: UUID) -> Bool {
        state.requireTwoFactor(operation: operation)
    }

    /// Bytes must already be validated/versioned SDK session material, never a
    /// password. Rejected callbacks cannot insert, overwrite or delete records.
    /// Teams must be freshly enumerated by the SDK, not supplied by account UI.
    @discardableResult
    func receiveAuthenticatedSession(
        operation: UUID, encodedSession: Data,
        teams: [AppleAccountSessionMetadata.Team], expiresAt: Date?, now: Date
    ) throws -> Bool {
        guard isPending(operation), revalidatingReference == nil else { return false }
        guard !cleanupRequired else { throw AppleAccountSessionCoordinatorError.cleanupRequired }
        // Validate before reserving/writing any durable record.
        var metadata = AppleAccountSessionMetadata(
            credentialReference: UUID(), teams: teams, expiresAt: expiresAt
        )
        guard metadata.isValid(at: now) else {
            throw AppleAccountSessionCoordinatorError.invalidSessionMetadata
        }
        let reference: UUID
        do {
            reference = try persistence.commitNewSession(encodedSession)
        } catch {
            // A reservation may now exist, even though commit threw. Never apply
            // the older insert-only store's no-write-on-throw assumption here.
            cleanupRequired = true
            state.failAuthentication(operation: operation)
            cancelAuthenticationTask()
            throw error
        }
        metadata = AppleAccountSessionMetadata(
            credentialReference: reference, teams: teams, expiresAt: expiresAt
        )
        // No await/reentrancy: journal selection is durable before acceptance.
        state.receiveAuthenticatedSession(operation: operation, session: metadata, now: now)
        authenticationTask = nil
        return true
    }

    @discardableResult
    func failAuthentication(operation: UUID) -> Bool {
        guard state.failAuthentication(operation: operation) else { return false }
        revalidatingReference = nil
        cancelAuthenticationTask()
        return true
    }

    @discardableResult
    func selectTeam(identifier: String, operation: UUID, now: Date) throws -> Bool {
        var proposed = state
        guard proposed.selectTeam(identifier: identifier, operation: operation, now: now),
              let reference = proposed.credentialReference else { return false }
        try persistence.saveSelectedTeamHint(identifier, reference: reference)
        state = proposed
        return true
    }

    @discardableResult
    func changeTeam(identifier: String, now: Date) throws -> Bool {
        var proposed = state
        guard proposed.changeTeam(identifier: identifier, now: now),
              let reference = proposed.credentialReference else { return false }
        try persistence.saveSelectedTeamHint(identifier, reference: reference)
        state = proposed
        return true
    }

    func expireSession() { state.expireSession() }

    func currentContext(at date: Date) -> AppleAccountAuthenticationState.Context? {
        state.currentContext(at: date)
    }

    /// Narrow internal lease for read-only provisioning preflight. No SDK bytes
    /// are exposed by public UI APIs. Durable reference must still match the
    /// selected, non-expired context; team hints alone cannot authorize access.
    func provisioningCandidate(contextID: UUID, now: Date) throws -> (context: AppleAccountAuthenticationState.Context, encodedSession: Data)? {
        guard !cleanupRequired, let context = state.currentContext(at: now),
              context.id == contextID, context.team.membership == .free else { return nil }
        guard let candidate = try persistence.recoverCandidate(),
              candidate.reference == context.session.credentialReference else { return nil }
        return (context, candidate.encodedSession)
    }

    func acceptsProvisioningResult(contextID: UUID, now: Date) -> Bool {
        state.acceptsProvisioningResult(contextID: contextID, now: now)
    }

    /// Invalidate first, persist deletion intent, then clean exact owned records.
    /// Failure remains visible/retryable, including failure to persist the intent.
    /// Local sign-out never revokes a portal certificate.
    func signOut() throws {
        cancelAuthenticationTask()
        state.signOut()
        revalidatingReference = nil
        cleanupRequired = true
        try persistence.signOut()
        cleanupRequired = false
    }

    /// Retry the entire durable sign-out, not merely an in-memory UUID set.
    func retryPendingDeletions() throws {
        guard cleanupRequired else { return }
        try signOut()
    }

    private func isPending(_ operation: UUID) -> Bool {
        switch state.phase {
        case .authenticating(let current), .awaitingTwoFactor(let current):
            return current == operation
        default:
            return false
        }
    }

    private func cancelAuthenticationTask() {
        authenticationTask?.cancel()
        authenticationTask = nil
    }
}
