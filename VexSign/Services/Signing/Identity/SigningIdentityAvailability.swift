import Foundation

/// One answer to "is there an identity that could still be used to sign?"
///
/// Update detection in Sources and paired-device planning previously disagreed: one
/// rejected revoked certificates, the other only looked at the expiration date. That let a
/// revoked identity advertise an installable update. This helper is the shared rule for
/// both surfaces and for the installation authorization check; the full signing preflight
/// remains authoritative for a particular IPA.
enum SigningIdentityAvailability {
    static func isUsable(_ certificate: CertificateRecord, at now: Date = Date()) -> Bool {
        guard !certificate.revoked else { return false }
        guard let expiration = certificate.expiration else { return true }
        return expiration > now
    }

    static func hasUsableIdentity(in certificates: [CertificateRecord], at now: Date = Date()) -> Bool {
        certificates.contains { isUsable($0, at: now) }
    }

    /// Expiry used by paired-device installation. A revoked identity has no valid
    /// authorization window, so it is represented as already expired and is blocked by
    /// the existing coordinator check instead of being treated as valid forever.
    static func installationExpiry(for certificate: CertificateRecord, at now: Date = Date()) -> Date? {
        guard isUsable(certificate, at: now) else { return .distantPast }
        return certificate.expiration
    }
}
