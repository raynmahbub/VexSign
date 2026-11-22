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
		let renewable = NativeRenewalCapability.isAvailable
		return records.map {
			SigningCredential(record: $0, canRenewOnDevice: renewable)
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
			canRenewOnDevice: NativeRenewalCapability.isAvailable
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
			for: SigningCredential(record: record, canRenewOnDevice: NativeRenewalCapability.isAvailable),
			now: now
		)
	}
}

// MARK: - Capability

/// Whether this build can renew a credential by itself.
///
/// Reads `SigningMethodCapabilities` rather than a preference, because turning this on is
/// not a user choice — it requires a native account adapter to be wired into provisioning.
/// When that happens, the capability flips in one place and every renewal status in the app
/// changes with it.
enum NativeRenewalCapability {
	static var isAvailable: Bool {
		SigningMethodCapabilities.current.nativeAppleAccountSigning == .implemented
	}
}
