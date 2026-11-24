import Foundation

/// Where a signing identity came from.
///
/// Not a security claim: it is the shape of the credential the user supplied, which is
/// what decides whether renewing it is something this device can do at all. An imported
/// `.p12` pair, a cloud-held identity and a free Apple Account identity all produce
/// installable apps and all expire, but only the last one can be renewed on device
/// without the user supplying new key material.
enum SigningCredentialKind: String, Codable, CaseIterable, Sendable {
	/// A `.p12` + provisioning profile pair the user imported.
	case importedPair
	/// A credential held by the cloud signer. This device holds no key material.
	case cloud
	/// A free Apple Account identity provisioned on device.
	case appleAccount
	/// A paid or enterprise identity managed outside the app.
	case managed
}

/// A credential as the renewal layer needs it: an identity to keep alive, not a
/// certificate row.
///
/// `CertificateHealth` answers "what is the state of this certificate now". This answers
/// "when must something happen to it, and is that something possible here". The two are
/// deliberately separate: a certificate can be perfectly healthy and still be the wrong
/// thing to schedule, and a scheduling plan is meaningless for an identity the app cannot
/// renew.
///
/// All times are absolute. Nothing here reads the clock, so a stored record never depends
/// on when it was read.
struct SigningCredential: Identifiable, Equatable, Sendable {
	let id: String
	let kind: SigningCredentialKind
	let name: String
	let teamID: String
	/// End of the provisioning profile (or of the cloud credential). This is the date
	/// iOS enforces: after it, installed apps stop launching.
	let expiresAt: Date
	/// The leaf certificate's own end date, when a status check has read it. The
	/// certificate can expire before the profile, and then signing fails early.
	let certificateExpiresAt: Date?
	/// When the credential was issued, when that is known. Used only to size the renewal
	/// window proportionally; `nil` falls back to a per-kind assumption.
	let issuedAt: Date?
	/// The issuer already revoked the identity. No renewal can repair this.
	let isRevoked: Bool
	/// Whether renewal can be attempted from this device. `false` is not a failure — it is
	/// the honest answer for an identity whose private key was never imported, or whose
	/// renewal needs a backend this build does not have.
	///
	/// Has a default only so that the memberwise initializer keeps `isRevoked`'s label
	/// order intact for callers that pass it positionally last.
	var canRenewOnDevice: Bool

	init(
		id: String,
		kind: SigningCredentialKind,
		name: String,
		teamID: String,
		expiresAt: Date,
		certificateExpiresAt: Date? = nil,
		issuedAt: Date? = nil,
		isRevoked: Bool = false,
		canRenewOnDevice: Bool = true
	) {
		self.id = id
		self.kind = kind
		self.name = name
		self.teamID = teamID
		self.expiresAt = expiresAt
		self.certificateExpiresAt = certificateExpiresAt
		self.issuedAt = issuedAt
		self.isRevoked = isRevoked
		self.canRenewOnDevice = canRenewOnDevice
	}

	/// The date at which this credential can no longer be used to sign.
	///
	/// The earlier of the two, because both are enforced at different stages: an expired
	/// profile fails at install, an expired certificate fails at signing.
	var effectiveExpiry: Date {
		guard let certificateExpiresAt else { return expiresAt }
		return min(expiresAt, certificateExpiresAt)
	}
}
