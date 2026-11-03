import Foundation
import SideSign

/// Per-worker profile authority, assembled by the isolated account bridge with
/// live owned-identity/context/consent checks, shared gate, deadline and lease.
/// Default missing CMS verifier still blocks before session/provider/portal I/O;
/// public factory/normal app have not promoted the unvalidated verifier.
actor SideSignBoundProfilePortal<Portal: SideSignProfileTransport>: NativeProfileCreationPortal {
    private struct Authorization: Sendable {
        let nonce: UUID
        let session: Session
        let team: Team
        let expiresAt: Date
    }
    private let portal: Portal
    private let owner: NativeSigningIdentityOwner
    private let contextID: UUID
    private let request: NativeProfileCreationRequest
    private let encodedSession: Data
    private let authorityExpiresAt: Date
    private let lifetime: any NativeAccountBackendLifetime
    private let validator: NativeProvisioningProfileValidator
    private let freshHeaders: @Sendable () async throws -> AnisetteData
    private let ownedIdentity: @Sendable () async throws -> NativeOwnedProfileIdentity
    private let checkCurrent: @Sendable () async throws -> Void
    private let clock: @Sendable () -> Date
    private var nonce = UUID()
    private var authorization: Authorization?

    init(portal: Portal, owner: NativeSigningIdentityOwner, contextID: UUID, request: NativeProfileCreationRequest,
         encodedSession: Data, authorityExpiresAt: Date, lifetime: any NativeAccountBackendLifetime,
         validator: NativeProvisioningProfileValidator = .init(),
         freshHeaders: @escaping @Sendable () async throws -> AnisetteData,
         ownedIdentity: @escaping @Sendable () async throws -> NativeOwnedProfileIdentity,
         checkCurrent: @escaping @Sendable () async throws -> Void,
         clock: @escaping @Sendable () -> Date = { Date() }) throws {
        try validator.requireCMSVerification()
        let now = clock()
        guard now.timeIntervalSince1970.isFinite, authorityExpiresAt.timeIntervalSince1970.isFinite,
              authorityExpiresAt > now, request.validation.teamIdentifier == owner.teamIdentifier,
              try SideSignSessionCodec.identityOwner(encodedSession, teamIdentifier: owner.teamIdentifier, now: now) == owner else {
            throw NativeProfileCreationError.invalidRequest
        }
        self.portal = portal; self.owner = owner; self.contextID = contextID; self.request = request
        self.encodedSession = encodedSession; self.authorityExpiresAt = authorityExpiresAt; self.lifetime = lifetime
        self.validator = validator; self.freshHeaders = freshHeaders; self.ownedIdentity = ownedIdentity
        self.checkCurrent = checkCurrent; self.clock = clock
    }

    func invalidate() { nonce = UUID(); authorization = nil }

    func revalidate(owner: NativeSigningIdentityOwner, contextID: UUID, request: NativeProfileCreationRequest) async throws {
        invalidate()
        let attempt = nonce
        do {
            guard owner == self.owner, contextID == self.contextID, request.approvalDigest == self.request.approvalDigest else {
                throw NativeProfileCreationError.approvalRequired
            }
            try await requireLive()
            let headers = try await freshHeaders() // no credential/target arguments
            try await requireLive()
            let auth = try await SideSignCertificateAdapter(portal: portal).authorize(encodedSession: encodedSession,
                headers: headers, teamIdentifier: owner.teamIdentifier, now: clock(), checkCurrent: { try await self.requireLive() })
            try await requireLive()
            let device = try NativeRegistrationSubject(kind: .device, value: request.validation.deviceIdentifier)
            let devices = try await portal.registrationInventory(subject: device, team: auth.team, session: auth.session)
            try await requireLive()
            try NativeProfileResourcePolicy.requireRegistration(devices, subject: device, remoteIdentifier: request.deviceID, now: clock(), requireExpiry: false)
            let app = try NativeRegistrationSubject(kind: .appID, value: request.validation.bundleIdentifier)
            let apps = try await portal.registrationInventory(subject: app, team: auth.team, session: auth.session)
            try await requireLive()
            try NativeProfileResourcePolicy.requireRegistration(apps, subject: app, remoteIdentifier: request.appID, now: clock(), requireExpiry: true)
            let observations = try await portal.profileCertificateInventory(team: auth.team, session: auth.session)
            try await requireLive()
            try NativeProfileResourcePolicy.requireCertificate(observations, request: request)
            try await requireLive()
            guard nonce == attempt, let expiry = auth.session.expirationDate, expiry > clock() else {
                throw NativeProfileCreationError.approvalRequired
            }
            authorization = Authorization(nonce: attempt, session: auth.session, team: auth.team,
                expiresAt: min(authorityExpiresAt, min(expiry, clock().addingTimeInterval(30))))
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if let safe = error as? NativeProfileCreationError { throw safe }
            if let safe = error as? NativeProfileValidationError { throw safe }
            throw NativeProfileCreationError.requestFailed
        }
    }

    func inventory(request: NativeProfileCreationRequest) async throws -> [NativeProfileObservation] {
        let authorized = try await currentAuthorization(request)
        try requireNonce(authorized)
        let rows = try await portal.profileInventory(request: request, team: authorized.team, session: authorized.session,
            checkCurrent: { _ = try await self.currentAuthorization(request) })
        let current = try await currentAuthorization(request)
        guard current.nonce == authorized.nonce else { throw NativeProfileCreationError.approvalRequired }
        return rows
    }

    func createOnce(request: NativeProfileCreationRequest, operationID: UUID) async throws {
        let authorized = try await currentAuthorization(request)
        guard request.validation.expectedUUID == nil else { throw NativeProfileCreationError.invalidRequest }
        try requireNonce(authorized)
        try await portal.createLimitedProfileOnce(request: request, operationID: operationID, team: authorized.team, session: authorized.session)
        let current = try await currentAuthorization(request)
        guard current.nonce == authorized.nonce else { throw NativeProfileCreationError.approvalRequired }
    }

    private func requireNonce(_ authorized: Authorization) throws {
        let now = clock()
        guard now.timeIntervalSince1970.isFinite, authorized.expiresAt > now, authorityExpiresAt > now,
              nonce == authorized.nonce, authorization?.nonce == authorized.nonce else { throw NativeProfileCreationError.approvalRequired }
    }

    private func currentAuthorization(_ request: NativeProfileCreationRequest) async throws -> Authorization {
        guard request.approvalDigest == self.request.approvalDigest else { throw NativeProfileCreationError.approvalRequired }
        try await requireLive()
        guard let authorization, authorization.nonce == nonce, authorization.expiresAt > clock() else {
            throw NativeProfileCreationError.approvalRequired
        }
        return authorization
    }

    private func requireLive() async throws {
        try Task.checkCancellation()
        try validator.requireCMSVerification()
        try await checkCurrent()
        try Task.checkCancellation()
        let owned = try await ownedIdentity()
        try Task.checkCancellation()
        try NativeProfileResourcePolicy.requireOwned(owned, request: request)
        // Recheck external authority AFTER the vault callback's actor hop.
        try await checkCurrent()
        try Task.checkCancellation()
        let now = clock()
        guard now.timeIntervalSince1970.isFinite, authorityExpiresAt > now else { throw NativeProfileCreationError.approvalRequired }
    }
}
