import Foundation
import SideSign

/// Internal session-bound adapter for the registration executor. The future
/// bridge must provide real consent/context checks, its shared busy gate and
/// namespace lifetime; constructing this is not proof of a user approval.
actor SideSignBoundRegistrationPortal<Portal: SideSignRegistrationTransport>: NativeRegistrationPortal {
    private struct Authorization: Sendable {
        let nonce: UUID
        let session: Session
        let team: Team
        let expiresAt: Date
    }
    private let portal: Portal
    private let owner: NativeSigningIdentityOwner
    private let contextID: UUID
    private let encodedSession: Data
    private let authorityExpiresAt: Date
    private let freshHeaders: @Sendable () async throws -> AnisetteData
    private let checkCurrent: @Sendable () async throws -> Void
    private let clock: @Sendable () -> Date
    private let lifetime: any NativeAccountBackendLifetime
    private var nonce = UUID()
    private var authorization: Authorization?

    init(portal: Portal, owner: NativeSigningIdentityOwner, contextID: UUID, encodedSession: Data,
         authorityExpiresAt: Date, lifetime: any NativeAccountBackendLifetime,
         freshHeaders: @escaping @Sendable () async throws -> AnisetteData,
         checkCurrent: @escaping @Sendable () async throws -> Void,
         clock: @escaping @Sendable () -> Date = { Date() }) throws {
        let now = clock()
        guard now.timeIntervalSince1970.isFinite, authorityExpiresAt.timeIntervalSince1970.isFinite,
              authorityExpiresAt > now,
              try SideSignSessionCodec.identityOwner(encodedSession, teamIdentifier: owner.teamIdentifier, now: now) == owner else {
            throw NativeRegistrationError.approvalRequired
        }
        self.portal = portal; self.owner = owner; self.contextID = contextID; self.encodedSession = encodedSession
        self.authorityExpiresAt = authorityExpiresAt; self.lifetime = lifetime
        self.freshHeaders = freshHeaders; self.checkCurrent = checkCurrent; self.clock = clock
    }

    func invalidate() { nonce = UUID(); authorization = nil }

    func revalidateFreeAccount(owner: NativeSigningIdentityOwner, contextID: UUID) async throws {
        invalidate()
        let attempt = nonce
        do {
            guard owner == self.owner, contextID == self.contextID else { throw NativeRegistrationError.approvalRequired }
            try await requireLive()
            let headers = try await freshHeaders() // no account/target arguments
            try await requireLive()
            let auth = try await SideSignCertificateAdapter(portal: portal).authorize(encodedSession: encodedSession,
                headers: headers, teamIdentifier: owner.teamIdentifier, now: clock(), checkCurrent: { try await self.requireLive() })
            try await requireLive()
            guard nonce == attempt, let expiry = auth.session.expirationDate, expiry > clock() else {
                throw NativeRegistrationError.approvalRequired
            }
            authorization = Authorization(nonce: attempt, session: auth.session, team: auth.team,
                expiresAt: min(authorityExpiresAt, min(expiry, clock().addingTimeInterval(30))))
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if let safe = error as? NativeRegistrationError { throw safe }
            throw NativeRegistrationError.requestFailed
        }
    }

    func inventory(subject: NativeRegistrationSubject) async throws -> [NativeRegistrationObservation] {
        let authorized = try await currentAuthorization()
        guard authorization?.nonce == authorized.nonce, nonce == authorized.nonce else { throw NativeRegistrationError.approvalRequired }
        let rows = try await portal.registrationInventory(subject: subject, team: authorized.team, session: authorized.session)
        let current = try await currentAuthorization()
        guard current.nonce == authorized.nonce else { throw NativeRegistrationError.approvalRequired }
        return rows
    }

    func registerOnce(subject: NativeRegistrationSubject, operationID: UUID) async throws {
        let authorized = try await currentAuthorization()
        guard authorization?.nonce == authorized.nonce, nonce == authorized.nonce else { throw NativeRegistrationError.approvalRequired }
        try await portal.registerSubjectOnce(subject, operationID: operationID, team: authorized.team, session: authorized.session)
        let current = try await currentAuthorization()
        guard current.nonce == authorized.nonce else { throw NativeRegistrationError.approvalRequired }
    }

    private func currentAuthorization() async throws -> Authorization {
        try await requireLive()
        guard let authorization, authorization.nonce == nonce, authorization.expiresAt > clock() else {
            throw NativeRegistrationError.approvalRequired
        }
        return authorization
    }

    private func requireLive() async throws {
        try Task.checkCancellation()
        try await checkCurrent()
        try Task.checkCancellation()
        let now = clock()
        guard now.timeIntervalSince1970.isFinite, authorityExpiresAt > now else { throw NativeRegistrationError.approvalRequired }
    }
}
