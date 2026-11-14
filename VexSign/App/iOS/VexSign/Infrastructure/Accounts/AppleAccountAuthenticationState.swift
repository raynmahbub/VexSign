import Foundation

/// Non-secret metadata only. A Keychain adapter owns the actual session material.
/// This is intentionally not Codable: pending authentication must not be restored
/// after relaunch, and neither passwords nor portal tokens belong in preferences.
struct AppleAccountSessionMetadata: Equatable, Sendable {
    struct Team: Equatable, Sendable {
        enum Membership: Equatable, Sendable {
            case free, paid
            // SDK individual/organization categories do not prove active paid
            // enrollment. Provisioning eligibility must be verified separately.
            case developerProgramUnverified
        }
        let identifier: String
        let membership: Membership
    }

    let credentialReference: UUID
    let teams: [Team]
    let expiresAt: Date?

    func isValid(at date: Date) -> Bool {
        !teams.isEmpty && teams.allSatisfy { !$0.identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            && Set(teams.map(\.identifier)).count == teams.count
            && (expiresAt.map { $0 > date } ?? true)
    }
}

/// Lifecycle foundation for the forthcoming native SideSign adapter; this does
/// not authenticate an account or claim that a native signing engine is linked.
/// The coordinator must serialize mutations and cancel its actual network tasks.
struct AppleAccountAuthenticationState: Sendable {
    struct Context: Equatable, Sendable {
        let id: UUID
        let session: AppleAccountSessionMetadata
        let team: AppleAccountSessionMetadata.Team
    }

    enum Phase: Equatable, Sendable {
        case signedOut
        case authenticating(UUID)
        case awaitingTwoFactor(UUID)
        case awaitingTeamSelection(UUID, AppleAccountSessionMetadata)
        case signedIn(Context)
        case expired(AppleAccountSessionMetadata)
    }

    private(set) var phase: Phase = .signedOut

    /// Retrying a pending login invalidates previous challenge/completion IDs.
    /// Existing credential references must first be removed through signOut().
    mutating func beginAuthentication() -> UUID? {
        switch phase {
        case .signedOut, .authenticating, .awaitingTwoFactor:
            let operation = UUID()
            phase = .authenticating(operation)
            return operation
        case .awaitingTeamSelection, .signedIn, .expired:
            return nil
        }
    }

    private func accepts(_ operation: UUID) -> Bool {
        switch phase {
        case .authenticating(let current), .awaitingTwoFactor(let current): return operation == current
        default: return false
        }
    }

    @discardableResult
    mutating func requireTwoFactor(operation: UUID) -> Bool {
        guard accepts(operation) else { return false }
        phase = .awaitingTwoFactor(operation)
        return true
    }

    /// No automatic first-team/free-team selection. A user must choose the team.
    @discardableResult
    mutating func receiveAuthenticatedSession(operation: UUID, session: AppleAccountSessionMetadata, now: Date) -> Bool {
        guard accepts(operation), session.isValid(at: now) else { return false }
        phase = .awaitingTeamSelection(operation, session)
        return true
    }

    @discardableResult
    mutating func selectTeam(identifier: String, operation: UUID, now: Date) -> Bool {
        guard case .awaitingTeamSelection(let current, let session) = phase,
              operation == current, session.isValid(at: now),
              let team = session.teams.first(where: { $0.identifier == identifier }) else { return false }
        phase = .signedIn(Context(id: UUID(), session: session, team: team))
        return true
    }

    /// Switching teams invalidates in-flight provisioning/signing context IDs.
    @discardableResult
    mutating func changeTeam(identifier: String, now: Date) -> Bool {
        guard case .signedIn(let context) = phase, context.session.isValid(at: now),
              let team = context.session.teams.first(where: { $0.identifier == identifier }) else { return false }
        phase = .signedIn(Context(id: UUID(), session: context.session, team: team))
        return true
    }

    func currentContext(at date: Date) -> Context? {
        guard case .signedIn(let context) = phase, context.session.isValid(at: date) else { return nil }
        return context
    }

    func acceptsProvisioningResult(contextID: UUID, now: Date) -> Bool {
        guard let context = currentContext(at: now), context.team.membership != .developerProgramUnverified else { return false }
        return context.id == contextID
    }

    @discardableResult
    mutating func failAuthentication(operation: UUID) -> Bool {
        guard accepts(operation) else { return false }
        phase = .signedOut
        return true
    }

    mutating func expireSession() {
        switch phase {
        case .signedIn(let context): phase = .expired(context.session)
        case .awaitingTeamSelection(_, let session): phase = .expired(session)
        default: break
        }
    }

    /// A rejected duplicate callback must not delete an already accepted record.
    var credentialReference: UUID? {
        switch phase {
        case .awaitingTeamSelection(_, let session), .expired(let session): return session.credentialReference
        case .signedIn(let context): return context.session.credentialReference
        default: return nil
        }
    }

    /// Caller must cancel pending requests and delete this Keychain record.
    /// Sign-out is local; it must not silently revoke a portal certificate.
    @discardableResult
    mutating func signOut() -> UUID? {
        let reference = credentialReference
        phase = .signedOut
        return reference
    }
}
