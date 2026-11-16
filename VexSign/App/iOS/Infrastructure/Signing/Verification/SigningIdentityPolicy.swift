import Foundation

/// Cheap run admission only. CertificatePair.expiration is the primary PROFILE's
/// date, not the PKCS#12 leaf's date; a current additional profile can legitimately
/// replace that expired primary profile. Never mislabel it as certificate expiry.
///
/// The coordinator authenticates the complete component plan before copying, and
/// the execution gate proves the actual leaf/key and checks both validity windows
/// again before signing. Missing cached dates here never establish readiness.
extension SigningIdentityPolicy {
    @MainActor
    static func rejection(for request: SigningRequest, now: Date = Date()) -> Rejection? {
        guard request.options.signingOption == .default else { return nil }
        guard let certificate = request.certificate else { return .missingCertificate }
        return rejection(for: certificate, now: now)
    }

    /// Detached-worker variant. Resolve current certificate state from the opaque
    /// reference on MainActor rather than capturing a managed object in the request.
    @MainActor
    static func rejection(for request: SigningWorkRequest, now: Date = Date()) -> Rejection? {
        guard request.options.signingOption == .default else { return nil }
        guard let reference = request.certificateID else { return .missingCertificate }
        do {
            let certificate = try Storage.shared.managedCertificate(id: reference)
            return rejection(for: certificate, now: now)
        } catch {
            return .missingCertificate
        }
    }

    @MainActor
    static func rejection(for certificate: CertificatePair, now: Date = Date()) -> Rejection? {
        let snapshot = certificate.uuid.flatMap { CertificateRevocationSnapshot.stored(forCertificateUUID: $0) }
        return rejection(for: certificate, storedSnapshot: snapshot, now: now)
    }

    /// The injected snapshot is public status evidence, never a trust/key token.
    @MainActor
    static func rejection(for certificate: CertificatePair, storedSnapshot: CertificateRevocationSnapshot?,
                          now: Date = Date()) -> Rejection? {
        if certificate.revoked { return .certificateRevoked }
        return rejection(storedSnapshot: storedSnapshot, now: now)
    }
}
