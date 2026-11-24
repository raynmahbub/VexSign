import Foundation

struct CertCheckResult: Identifiable, Equatable {
	enum Status: Equatable {
		case valid
		case expiringSoon
		case expired
		case revoked
		case unreadable
		/// In date and not marked revoked, but no revocation answer was obtained. Kept apart
		/// from `valid`, which is a claim that the certificate was checked.
		case notChecked
	}

	let id: String
	let name: String
	let teamID: String
	let expiryDate: Date?
	let daysRemaining: Int?
	let isRevoked: Bool
	let isPPQLess: Bool
	let supportsJIT: Bool
	let status: Status
	let detail: String

	static func make(
		id: String,
		name: String,
		teamID: String,
		expiryDate: Date?,
		isRevoked: Bool,
		isPPQLess: Bool,
		revocationKnown: Bool,
		detail: String = ""
	) -> CertCheckResult {
		let daysRemaining = expiryDate.map { Int(floor($0.timeIntervalSinceNow / 86_400)) }

		let status: Status
		if isRevoked {
			status = .revoked
		} else if let expiryDate, expiryDate <= Date() {
			status = .expired
		} else if let daysRemaining, daysRemaining < 7 {
			status = .expiringSoon
		} else if expiryDate == nil, !revocationKnown {
			status = .unreadable
		} else if !revocationKnown {
			status = .notChecked
		} else {
			status = .valid
		}

		return CertCheckResult(
			id: id,
			name: name,
			teamID: teamID,
			expiryDate: expiryDate,
			daysRemaining: daysRemaining,
			isRevoked: isRevoked,
			isPPQLess: isPPQLess,
			supportsJIT: !isPPQLess,
			status: status,
			detail: detail
		)
	}

}
