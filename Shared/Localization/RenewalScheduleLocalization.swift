//
//  RenewalScheduleLocalization.swift
//  VexSign
//
//  Words for the renewal schedule. Same shape as
//  `CertificateStatusLocalization.swift`: the domain type carries the decision, the
//  platform layer carries the English, and the two cannot drift because this is the only
//  place the strings exist.
//
//  Wording rules, matching the rest of the app:
//
//    * Always state the deadline and the consequence. Never "expiring soon".
//    * Never claim a renewal happened. `blocked` says a person has to act; it does not say
//      work was queued.
//    * "Signed app" is the subject, because the user cares about the app that stops
//      launching, not about a provisioning profile they never see.
//

import Foundation
import NimbleExtensions

extension RenewalStatus {
	var title: String {
		switch self {
		case .notDue: .localized("Scheduled")
		case .due: .localized("Renewal due")
		case .urgent: .localized("Renew now")
		case .lapsed: .localized("Expired")
		case .blocked: .localized("Cannot renew here")
		case .unknown: .localized("Expiry unknown")
		}
	}

	var icon: String {
		switch self {
		case .notDue: "calendar.badge.clock"
		case .due: "clock.arrow.circlepath"
		case .urgent: "exclamationmark.triangle.fill"
		case .lapsed: "xmark.octagon.fill"
		case .blocked: "lock.slash.fill"
		case .unknown: "questionmark.circle"
		}
	}

	/// One sentence saying what the status rests on. Kept apart from `title` because a row
	/// needs a label and a detail, and the detail is where honesty costs words.
	var explanation: String {
		switch self {
		case .notDue:
			.localized("This signing profile is still valid. Re-sign before it expires so the app keeps opening.")
		case .due:
			.localized("The signing profile is inside its renewal window. Re-signing now replaces it while the current one still works.")
		case .urgent:
			.localized("The signing profile expires very soon. Apps signed with it stop opening once it lapses.")
		case .lapsed:
			.localized("The signing profile has expired. Apps signed with it no longer open, but their data is still on the device.")
		case .blocked:
			.localized("This credential cannot be renewed on this device. Revoked identities and cloud-held keys need new signing material rather than a renewal.")
		case .unknown:
			.localized("No usable expiry date could be read for this profile, so no renewal can be scheduled.")
		}
	}
}

extension RenewalPlan {
	/// One line for a list row. Says what happens and when, never what to be afraid of.
	var summary: String {
		switch status {
		case .notDue:
			.localized("Renews in %lld days", arguments: daysRemaining)
		case .due:
			.localized("Renew within %lld days", arguments: daysRemaining)
		case .urgent:
			daysRemaining <= 0
				? .localized("Expires today")
				: .localized("Expires in %lld days", arguments: daysRemaining)
		case .lapsed:
			.localized("Expired %lld days ago", arguments: abs(daysRemaining))
		case .blocked:
			.localized("Expires in %lld days — needs a new certificate", arguments: daysRemaining)
		case .unknown:
			.localized("No expiry date could be read")
		}
	}

	/// Detail for a certificate row: the deadline plus the consequence.
	var detail: String {
		let date = DateFormatter()
		date.dateStyle = .medium
		date.timeStyle = .none
		return .localized(
			"Signing stops on %@. %@",
			arguments: date.string(from: expiresAt), status.explanation
		)
	}
}
