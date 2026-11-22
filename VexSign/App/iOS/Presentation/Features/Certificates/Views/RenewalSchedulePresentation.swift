//
//  RenewalSchedulePresentation.swift
//  VexSign
//
//  The bridge between the stored certificate list and `RenewalPlanner`.
//
//  Why this exists as its own file: three different screens will want the same answer
//  ("is this credential about to stop signing, and can it be fixed here?"), and the
//  previous behaviour — a bare `expiration < 7 days` check in the header and an
//  `isExpiringSoon` flag inside `NativeSigningManager` — gave three opinions about the
//  same certificate. Everything now routes through `RenewalPlanner` so the row, the
//  header and the background pass cannot disagree.
//
//  This is presentation, not domain: it may import SwiftUI for the pill colour, and it
//  may reach for `SigningMethodCapabilities` because "can this build renew at all" is a
//  fact about the implementation, not about the certificate.
//

import SwiftUI
import NimbleViews
import NimbleExtensions

@MainActor
enum RenewalSchedulePresentation {
	/// Credentials for the current list, with the renewal path this build actually has.
	///
	/// `kind` is left at the importer default on purpose. `CertificateRecord` carries no
	/// origin, and guessing "this is a free Apple Account profile" from a seven-day window
	/// would be exactly the kind of inference that puts a wrong deadline on screen.
	static func credentials(from records: [CertificateRecord]) -> [SigningCredential] {
		records.map {
			SigningCredential(record: $0, canRenewOnDevice: Renewability.importedPair)
		}
	}

	/// Recompute the shared schedule from a snapshot the caller already has.
	///
	/// Called from the certificate list's appearance and after a status refresh. Cheap:
	/// a handful of date comparisons.
	@discardableResult
	static func refresh(records: [CertificateRecord], now: Date = Date()) -> [RenewalPlan] {
		RenewalScheduleCoordinator.shared.refresh(
			credentials: credentials(from: records),
			names: Dictionary(
				records.map { ($0.id, $0.nickname ?? $0.profile?.Name ?? "") },
				uniquingKeysWith: { first, _ in first }
			),
			now: now
		)
	}

	/// The pill for one row, or `nil` when there is nothing to say.
	///
	/// `notDue` deliberately produces no pill: a one-year certificate that is simply fine
	/// must not compete for space with the status and compatibility pills the row already
	/// carries. The information is still available on the detail screen.
	static func pill(for record: CertificateRecord, now: Date = Date()) -> NBPillItem? {
		let credential = SigningCredential(
			record: record,
			canRenewOnDevice: Renewability.importedPair
		)
		let plan = RenewalPlanner.plan(for: credential, now: now)
		guard plan.status != .notDue else { return nil }
		return NBPillItem(
			title: plan.status.title,
			icon: plan.status.icon,
			color: color(for: plan.status)
		)
	}

	static func color(for status: RenewalStatus) -> Color {
		switch status {
		case .notDue: .green
		case .due: .yellow
		case .urgent: .orange
		case .lapsed: .red
		case .blocked: .secondary
		case .unknown: .gray
		}
	}

	/// A single credential's plan for a detail screen.
	static func plan(for record: CertificateRecord, now: Date = Date()) -> RenewalPlan {
		RenewalPlanner.plan(
			for: SigningCredential(record: record, canRenewOnDevice: Renewability.importedPair),
			now: now
		)
	}
}

// MARK: - Renewability

/// Whether renewed signing material can be obtained on this device.
///
/// Deliberately **not** `SigningMethodCapabilities.nativeAppleAccountSigning`. That flag
/// answers a different question — whether this build signs an in-process CMS signature
/// against the Apple account — and it is held closed by a device-evidence gate, not by the
/// state of any code. Renewal is not that: a certificate imported from a free account is an
/// ordinary `CertificatePair`, and renewing it means provisioning a fresh profile and
/// re-importing the pair, which the account flow already does.
///
/// Conflating the two is what made the first version of this screen report `Cannot renew
/// here` for every free-account certificate, which was both wrong and the most alarming
/// thing the UI could say.
enum Renewability {
	/// Re-signing with fresh material the user supplies is always available; an imported
	/// `.p12` + profile pair is the ordinary path and needs no account session.
	static let importedPair = true

	/// A free-account profile can only be renewed while a signed-in session exists to
	/// provision with. Without one there is nothing to ask Apple for, and the status is
	/// `blocked` rather than a countdown that cannot be acted on.
	///
	/// The session state is published as a plain, value-only flag rather than reached for
	/// here: `NativeSigningManager` is a consumed engine owner that presentation must not
	/// name (`presentation_consumed_engine_owners` in the architecture ratchet). Keeping the
	/// dependency on the infrastructure side is why the account flow owns the refresh.
	@MainActor
	static var freeAccount: Bool { RenewalRenewabilityState.shared.isAccountSessionReady }
}
