import Foundation

public enum NativeCertificateStatusConsentError: Error, Equatable, Sendable {
    case busy, consentRequired, invalidLifetime
}

/// Separate disclosure approval: system OCSP/CRL status checks may contact the
/// certificate infrastructure and disclose certificate identifiers. Not anisette
/// consent, profile/certificate quota approval, or approval to sign/install.
public struct NativeCertificateStatusConsent: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let id: UUID
    let contextID: UUID
    let identityID: UUID
    let ownerDigest: String
    let certificateSHA256: String
    let flow: UUID
    let epoch: UUID
    let issuedAt: Date
    let expiresAt: Date
    let monotonicDeadline: ContinuousClock.Instant
    fileprivate init(contextID: UUID, identityID: UUID, owner: NativeSigningIdentityOwner, certificate: Data,
                     flow: UUID, epoch: UUID, issuedAt: Date, expiresAt: Date, lifetime: TimeInterval) {
        id = UUID(); self.contextID = contextID; self.identityID = identityID; ownerDigest = owner.digest
        certificateSHA256 = NativeSigningIdentityOwner.hash(certificate)
        self.flow = flow; self.epoch = epoch; self.issuedAt = issuedAt; self.expiresAt = expiresAt
        monotonicDeadline = ContinuousClock().now.advanced(by: .seconds(lifetime))
    }
    public var description: String { "NativeCertificateStatusConsent(redacted)" }
    public var debugDescription: String { description }
}

struct NativeCertificateStatusAuthorization: Sendable {
    let gate: NativeCertificateStatusConsentGate
    let consent: NativeCertificateStatusConsent
    let flow: UUID
}

/// At most one grant/online evaluation. Revocation invalidates authority without
/// releasing an uncooperative OS worker's slot. No persistence/automatic renewal.
actor NativeCertificateStatusConsentGate {
    private var epoch = UUID()
    private var pending: NativeCertificateStatusConsent?
    private var active: (id: UUID, consent: NativeCertificateStatusConsent)?

    func recordExplicitConsent(owner: NativeSigningIdentityOwner, contextID: UUID, identityID: UUID,
                               certificate: Data, flow: UUID, now: Date,
                               lifetime: TimeInterval = 120) throws -> NativeCertificateStatusConsent {
        try Task.checkCancellation()
        guard active == nil else { throw NativeCertificateStatusConsentError.busy }
        guard now.timeIntervalSince1970.isFinite, lifetime.isFinite, lifetime > 0, lifetime <= 120,
              !certificate.isEmpty, certificate.count <= 64 * 1024 else { throw NativeCertificateStatusConsentError.invalidLifetime }
        let expiry = now.addingTimeInterval(lifetime)
        guard expiry.timeIntervalSince1970.isFinite, expiry > now else { throw NativeCertificateStatusConsentError.invalidLifetime }
        let token = NativeCertificateStatusConsent(contextID: contextID, identityID: identityID, owner: owner,
            certificate: certificate, flow: flow, epoch: epoch, issuedAt: now, expiresAt: expiry, lifetime: lifetime)
        pending = token
        return token
    }
    func begin(_ authorization: NativeCertificateStatusConsent, owner: NativeSigningIdentityOwner,
               contextID: UUID, identityID: UUID, certificate: Data, flow: UUID, now: Date) throws -> UUID {
        try Task.checkCancellation()
        guard active == nil else { throw NativeCertificateStatusConsentError.busy }
        guard pending == authorization else { throw NativeCertificateStatusConsentError.consentRequired }
        pending = nil // consume before any online setup, including failed bindings
        guard authorization.epoch == epoch, authorization.flow == flow,
              authorization.ownerDigest == owner.digest, authorization.contextID == contextID,
              authorization.identityID == identityID,
              authorization.certificateSHA256 == NativeSigningIdentityOwner.hash(certificate),
              now.timeIntervalSince1970.isFinite, now >= authorization.issuedAt, now < authorization.expiresAt,
              ContinuousClock().now < authorization.monotonicDeadline else { throw NativeCertificateStatusConsentError.consentRequired }
        let id = UUID(); active = (id, authorization)
        return id
    }
    func requireCurrent(_ id: UUID, now: Date) throws {
        try Task.checkCancellation()
        guard let active, active.id == id, active.consent.epoch == epoch,
              now.timeIntervalSince1970.isFinite, now >= active.consent.issuedAt, now < active.consent.expiresAt,
              ContinuousClock().now < active.consent.monotonicDeadline else { throw NativeCertificateStatusConsentError.consentRequired }
    }
    func finish(_ id: UUID) { if active?.id == id { active = nil } }
    func revoke() { epoch = UUID(); pending = nil } // active stays until actual finish
}

public struct NativeAccountCertificateStatus: Sendable {
    public let certificateSHA256: String
    public let checkedAt: Date
    // Metadata only. No certificate/identity/session export or cached sign permit.
    init(_ result: NativeDevelopmentCertificateEvaluation) {
        certificateSHA256 = result.certificateSHA256; checkedAt = result.evaluatedAt
    }
}
