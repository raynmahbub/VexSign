import Foundation

enum SigningIdentityPolicy {
	enum Rejection: Error, Equatable {
		/// `signingOption == .default` with no certificate attached.
		case missingCertificate
		/// The attached certificate's `notAfter` is at or before the run's start.
		case certificateExpired(expiresAt: Date)
		/// The certificate row is marked revoked.
		case certificateRevoked

	}

    static func rejection(for certificate: CertificateRecord, now: Date = Date()) -> Rejection? {
        // The management row carries its primary profile's expiry, not the
        // actual leaf's. A row alone cannot establish certificate validity.
        return certificate.revoked ? .certificateRevoked : nil
    }

	/// The signing certificate's own end date, when a status check has read it.
	///
	/// The row stores the profile's expiry. The certificate inside the `.p12` can end
	/// earlier, and then everything it signs is refused at install. `nil` means the date
	/// has not been read, which is not a reason to refuse.
	static func rejection(certificateExpiry: Date?, now: Date = Date()) -> Rejection? {
		guard let certificateExpiry, certificateExpiry <= now else { return nil }
		return .certificateExpired(expiresAt: certificateExpiry)
	}

	/// What the last status check recorded for this certificate.
	///
	/// A recorded revocation refuses the run even if the certificate row was not updated;
	/// the row and the snapshot are written separately. "No answer" and "not checked" are
	/// not revocations and refuse nothing.
	static func rejection(storedSnapshot snapshot: CertificateRevocationSnapshot?, now: Date = Date()) -> Rejection? {
		guard let snapshot else { return nil }
		if snapshot.status == .revoked { return .certificateRevoked }
		return rejection(certificateExpiry: snapshot.certificateExpires, now: now)
	}

}
