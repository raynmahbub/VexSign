//
//  RenewalCredentialMapping.swift
//  VexSign
//
//  The one conversion from what the workspace knows to what the renewal planner needs.
//
//  It lives here, on the boundary between the stored records and the domain, because it is
//  the only place that has to decide two things the planner must not guess:
//
//    * whether this credential can be renewed from this device at all, and
//    * which date actually decides the app's fate.
//
//  What it deliberately does NOT do: infer the credential kind. `CertificateRecord` has no
//  such field, and an imported `.p12` can come from a free Apple Account, a paid team or a
//  service. Guessing would put a wrong "7 days" next to a one-year profile, which is the
//  failure mode this feature exists to prevent. Callers that know pass the kind in; the
//  default is the one kind that is certainly imported, with renewal left to the caller.
//

import Foundation

extension SigningCredential {
	/// Build from a stored certificate row.
	///
	/// - Parameters:
	///   - record: the row as the workspace exposes it. Public metadata only.
	///   - kind: where the identity came from. Defaults to `.importedPair`.
	///   - certificateExpiresAt: the leaf's own end date, when a status check has read it.
	///     `nil` means "not read", which is not a reason to distrust the profile date.
	///   - canRenewOnDevice: whether a renewal path exists for this identity here. Defaults
	///     to `true` because an imported pair can always be re-signed with fresh material.
	init(
		record: CertificateRecord,
		kind: SigningCredentialKind = .importedPair,
		certificateExpiresAt: Date? = nil,
		canRenewOnDevice: Bool = true
	) {
		self.init(
			id: record.id,
			kind: kind,
			// Empty rather than a placeholder: presentation supplies the fallback word, so
			// this stays Foundation-only like the rest of `Domain`.
			name: record.nickname ?? record.profile?.Name ?? "",
			teamID: record.profile?.TeamIdentifier.first ?? "",
			expiresAt: record.expiration ?? record.profile?.ExpirationDate ?? .distantPast,
			certificateExpiresAt: certificateExpiresAt,
			issuedAt: record.profile?.CreationDate,
			isRevoked: record.revoked,
			canRenewOnDevice: canRenewOnDevice && !record.revoked
		)
	}

	/// Build the list for a whole snapshot.
	///
	/// Rows with no readable expiry produce an `unknown` plan instead of being dropped:
	/// a certificate the user can see in the list but not in the schedule reads as a bug.
	static func credentials(
		in snapshot: WorkspaceSnapshot,
		kind: SigningCredentialKind = .importedPair,
		canRenewOnDevice: Bool = true
	) -> [SigningCredential] {
		snapshot.certificates.map {
			SigningCredential(
				record: $0,
				kind: kind,
				canRenewOnDevice: canRenewOnDevice
			)
		}
	}
}
