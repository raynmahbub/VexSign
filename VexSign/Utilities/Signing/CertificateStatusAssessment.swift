//
//  CertificateStatusAssessment.swift
//  VexSign
//
//  One answer to "what is the state of this signing certificate?", built from everything
//  the device knows: the two expiry dates, the stored revocation flag, and what the last
//  revocation check actually established.
//
//  The rule this file exists for: a certificate is `valid` only on positive, recent
//  evidence. Not having expired is not evidence, a check that could not be completed is
//  not evidence, and neither is a "good" answer from last week. Each of those has its own
//  status so the screen can say what is known instead of rounding it to "fine" or "bad".
//
//  Pure: no file, network or clock access. Callers pass the dates and the evidence in.
//

import Foundation
import NimbleExtensions

// MARK: - Status

enum CertificateStatus: String, Codable, CaseIterable, Sendable {
	/// Not expired, not revoked, and a recent revocation check said so.
	case valid
	/// The signing certificate or its provisioning profile has passed its end date.
	case expired
	/// The issuer has revoked the certificate.
	case revoked
	/// Nothing recent enough to say either way.
	case unknown
	/// The revocation responder could not be reached. Says nothing about the certificate.
	case networkUnavailable
	/// Revocation cannot be checked for this certificate on this device.
	case unsupported

	/// Signing with this certificate produces an app iOS will not install or launch.
	var blocksSigning: Bool { self == .expired || self == .revoked }
}

// MARK: - Evidence

/// What one revocation check established. A failure to obtain an answer is never folded
/// into `good` or `revoked`.
enum CertificateRevocationEvidence: Equatable, Sendable {
	/// The responder answered that the certificate is not revoked, at this time.
	case good(checkedAt: Date)
	/// The responder answered that the certificate is revoked.
	case revoked
	/// No check has been made.
	case notChecked
	/// The check ran and no answer came back from the responder.
	case responderUnreachable
	/// A revocation check could not be set up for this certificate.
	case unsupported
	/// The check ended some other way that settles nothing about revocation.
	case inconclusive

	// OSStatus values `SecTrustEvaluateWithError` reports, from Security's SecBase.h.
	// Spelled out because the classifier is pure and tested without the framework.
	private static let certificateRevoked = -67_820
	private static let incompleteRevocationCheck = -67_635

	/// Reads the outcome of a failed trust evaluation that required a positive revocation
	/// answer. Only an explicit "revoked" becomes `revoked`; a check that could not be
	/// completed is `responderUnreachable`; every other failure — an expired leaf, an
	/// untrusted chain — is `inconclusive`, because it is not a statement about revocation.
	static func classify(trustErrorCode code: Int) -> CertificateRevocationEvidence {
		switch code {
		case certificateRevoked: .revoked
		case incompleteRevocationCheck: .responderUnreachable
		default: .inconclusive
		}
	}
}

// MARK: - Assessment

struct CertificateStatusAssessment: Equatable, Sendable {
	enum Reason: String, Sendable {
		case revokedByIssuer
		case revokedOnRecord
		case certificateExpired
		case profileExpired
		case positiveEvidence
		case evidenceTooOld
		case notChecked
		case responderUnreachable
		case revocationUnsupported
		case inconclusive
	}

	struct Input: Equatable, Sendable {
		/// End date of the signing certificate itself, when it has been read.
		var certificateExpiry: Date?
		/// End date of the provisioning profile.
		var profileExpiry: Date?
		/// A revocation recorded by an earlier check. Revocation is permanent, so a record
		/// outlives the evidence that produced it.
		var revokedOnRecord: Bool
		var evidence: CertificateRevocationEvidence
	}

	/// How long a "good" answer is shown as valid. A display rule, deliberately short: the
	/// manager asks again far sooner, and a device that has been offline for a day should
	/// say it does not know rather than repeat yesterday's answer.
	static let evidenceValidity: TimeInterval = 24 * 60 * 60

	let status: CertificateStatus
	let reason: Reason

	static func assess(
		_ input: Input,
		now: Date = Date(),
		evidenceValidity: TimeInterval = CertificateStatusAssessment.evidenceValidity
	) -> CertificateStatusAssessment {
		// Revocation first: it is the one fact that cannot be undone, and an expired
		// certificate that was also revoked should say why a renewal will not help.
		if input.evidence == .revoked {
			return CertificateStatusAssessment(status: .revoked, reason: .revokedByIssuer)
		}
		if input.revokedOnRecord {
			return CertificateStatusAssessment(status: .revoked, reason: .revokedOnRecord)
		}

		// Expiry needs no network and no evidence: a date in the past is the whole answer.
		if let expiry = input.certificateExpiry, expiry <= now {
			return CertificateStatusAssessment(status: .expired, reason: .certificateExpired)
		}
		if let expiry = input.profileExpiry, expiry <= now {
			return CertificateStatusAssessment(status: .expired, reason: .profileExpired)
		}

		switch input.evidence {
		case .good(let checkedAt):
			// Absolute distance, so a clock moved backwards cannot keep an old answer alive.
			guard abs(now.timeIntervalSince(checkedAt)) <= evidenceValidity else {
				return CertificateStatusAssessment(status: .unknown, reason: .evidenceTooOld)
			}
			return CertificateStatusAssessment(status: .valid, reason: .positiveEvidence)
		case .revoked:
			return CertificateStatusAssessment(status: .revoked, reason: .revokedByIssuer)
		case .notChecked:
			return CertificateStatusAssessment(status: .unknown, reason: .notChecked)
		case .responderUnreachable:
			return CertificateStatusAssessment(status: .networkUnavailable, reason: .responderUnreachable)
		case .unsupported:
			return CertificateStatusAssessment(status: .unsupported, reason: .revocationUnsupported)
		case .inconclusive:
			return CertificateStatusAssessment(status: .unknown, reason: .inconclusive)
		}
	}
}

// MARK: - Presentation

extension CertificateStatus {
	var title: String {
		switch self {
		case .valid: .localized("Valid")
		case .expired: .localized("Expired")
		case .revoked: .localized("Revoked")
		case .unknown: .localized("Unknown")
		case .networkUnavailable: .localized("Check Unavailable")
		case .unsupported: .localized("Check Unsupported")
		}
	}

	var icon: String {
		switch self {
		case .valid: "checkmark.seal"
		case .expired: "calendar.badge.exclamationmark"
		case .revoked: "xmark.octagon"
		case .unknown: "questionmark.circle"
		case .networkUnavailable: "wifi.slash"
		case .unsupported: "minus.circle"
		}
	}
}

extension CertificateStatusAssessment {
	/// One sentence saying what the status rests on.
	var explanation: String {
		switch reason {
		case .revokedByIssuer:
			.localized("The issuer reports this certificate as revoked. Apps signed with it will not install or open.")
		case .revokedOnRecord:
			.localized("An earlier check found this certificate revoked. Revocation is permanent.")
		case .certificateExpired:
			.localized("The signing certificate has passed its expiry date.")
		case .profileExpired:
			.localized("The provisioning profile has passed its expiry date.")
		case .positiveEvidence:
			.localized("A recent revocation check confirmed this certificate. This does not guarantee that a particular app will install.")
		case .evidenceTooOld:
			.localized("The last successful revocation check is more than a day old, so the current status is not known.")
		case .notChecked:
			.localized("Revocation has not been checked yet. Not having expired does not mean the certificate is valid.")
		case .responderUnreachable:
			.localized("The revocation service could not be reached. This says nothing about the certificate; try again when online.")
		case .revocationUnsupported:
			.localized("A revocation check could not be set up for this certificate on this device.")
		case .inconclusive:
			.localized("The last check ended without an answer about revocation.")
		}
	}
}
