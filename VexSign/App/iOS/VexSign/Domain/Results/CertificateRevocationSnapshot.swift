import Foundation

enum CertificateStatusValue: String, Codable, Sendable {
	case signed
	case revoked
	case unknown

	/// Maps an on-device OCSP result onto the badge vocabulary.
	///
	/// Only positive evidence becomes `signed`. An unanswered query, an offline
	/// device or an unparsable response stays `unknown` — never "good", because a
	/// certificate shown as valid when its status is unknown is worse than an
	/// honest question mark.
	init(revocation: CertificateHealth.Revocation) {
		switch revocation {
		case .good: self = .signed
		case .revoked: self = .revoked
		case .unknown: self = .unknown
		}
	}

}

struct CertificateRevocationSnapshot: Codable, Equatable, Sendable {
	/// How long a verdict is trusted before it is fetched again.
	static let defaultMaxAge: TimeInterval = 30 * 60

	/// Why a check produced no verdict, when the reason is known. Stored beside the
	/// verdict so "the responder did not answer" is not flattened into plain `unknown`.
	enum Gap: String, Codable, Sendable {
		case responderUnreachable
		case unsupported
	}

	let status: CertificateStatusValue
	/// The inspector's explanation of how the verdict was reached.
	let detail: String
	let checkedAt: Date
	/// Absent for a verdict, and in snapshots written before the reason was recorded.
	let gap: Gap?
	/// The signing certificate's own end date, which can fall before the profile's. A
	/// date only: nothing here can reconstruct the certificate.
	let certificateExpires: Date?

	init(
		status: CertificateStatusValue,
		detail: String,
		checkedAt: Date,
		gap: Gap? = nil,
		certificateExpires: Date? = nil
	) {
		self.status = status
		self.detail = detail
		self.checkedAt = checkedAt
		self.gap = gap
		self.certificateExpires = certificateExpires
	}

	init(health: CertificateHealth) {
		let gap: Gap?
		switch health.revocationEvidence {
		case .responderUnreachable: gap = .responderUnreachable
		case .unsupported: gap = .unsupported
		case .good, .revoked, .notChecked, .inconclusive: gap = nil
		}
		self.init(
			status: CertificateStatusValue(revocation: health.revocation),
			detail: health.detail,
			checkedAt: health.checkedAt,
			gap: gap,
			certificateExpires: health.certificateExpires
		)
	}

	/// The stored verdict as evidence for `CertificateStatusAssessment`.
	var evidence: CertificateRevocationEvidence {
		switch status {
		case .signed: return .good(checkedAt: checkedAt)
		case .revoked: return .revoked
		case .unknown:
			switch gap {
			case .responderUnreachable: return .responderUnreachable
			case .unsupported: return .unsupported
			case nil: return .inconclusive
			}
		}
	}

	/// The cache rule, split out so it can be unit tested without a server or a
	/// certificate.
	func isFresh(now: Date = Date(), maxAge: TimeInterval = CertificateRevocationSnapshot.defaultMaxAge) -> Bool {
		abs(now.timeIntervalSince(checkedAt)) <= maxAge
	}

}
