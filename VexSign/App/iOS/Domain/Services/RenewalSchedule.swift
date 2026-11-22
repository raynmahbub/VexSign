//
//  RenewalSchedule.swift
//  VexSign
//
//  When a signed app must be re-signed, and whether that is a thing this device can do.
//
//  The rule this file exists for: a free Apple Account profile lasts seven days. iOS
//  stops launching the app the moment it lapses, and the user finds out by tapping the
//  icon. Every other part of the app knows whether a certificate is healthy; none of them
//  knew when the app itself stops working.
//
//  Two deliberate refusals, both because this app is trusted with signed code:
//
//    * A renewal is never "due" without a date behind it. A credential with no readable
//      expiry produces `unknown`, not a guess, because an invented date either panics the
//      user or (worse) hides a real lapse.
//    * A renewal that cannot be performed here is never reported as scheduled work. The
//      status `blocked` says a human has to act; it does not pretend something was queued.
//
//  Pure: no clock, no file, no network, and Foundation only. Human-facing text lives in
//  `Platform/Apple/Localization/RenewalScheduleLocalization.swift`, as it does for every
//  other domain status in this app.
//

import Foundation

// MARK: - Status

enum RenewalStatus: String, Codable, CaseIterable, Sendable {
	/// More than one renewal window away. Nothing to do.
	case notDue
	/// Inside the renewal window. Signing now avoids a lapse.
	case due
	/// Inside the final part of the window. A lapse is likely before the user next looks.
	case urgent
	/// The credential has already lapsed. Installed copies no longer launch.
	case lapsed
	/// A renewal is due, but this device cannot perform it: there is no renewal path for
	/// this credential kind, or it was revoked and must be replaced rather than renewed.
	case blocked
	/// There is no date to plan against.
	case unknown

	/// Only these two mean the user must act now.
	var requiresAttention: Bool { self == .urgent || self == .lapsed }

	/// Whether a background pass may attempt this one. `blocked` is deliberately excluded:
	/// spending a background slot on work that cannot succeed produces a notification
	/// nobody can act on.
	var isActionable: Bool { self == .due || self == .urgent }

	var isTerminal: Bool { self == .lapsed || self == .blocked }
}

// MARK: - Plan

/// One credential's renewal plan, expressed as a deadline rather than a timer.
///
/// Timers are not used on purpose: iOS decides when background work runs, and a countdown
/// that silently stops is worse than a date the UI recomputes on every appearance.
struct RenewalPlan: Identifiable, Equatable, Sendable {
	let credentialID: String
	/// Start of the window in which renewing is worthwhile.
	let renewAfter: Date
	/// The last date on which this credential still signs and installs.
	let expiresAt: Date
	let window: TimeInterval
	/// Whole days until `expiresAt`, floored, and negative once lapsed. Days are what the
	/// certificate screens already show, so the same unit is reused rather than inventing
	/// a second, fractional vocabulary.
	let daysRemaining: Int
	let status: RenewalStatus

	var id: String { credentialID }

	/// Fraction of the renewal window that has elapsed, clamped to 0...1. `nil` when the
	/// window is empty, so a caller cannot divide by zero to draw a progress bar.
	func elapsedFraction(now: Date) -> Double? {
		guard window > 0 else { return nil }
		let start = expiresAt.addingTimeInterval(-window)
		let elapsed = now.timeIntervalSince(start)
		return min(1, max(0, elapsed / window))
	}
}

// MARK: - Planner

enum RenewalPlanner {
	/// Bounds for the renewal window.
	///
	/// A free Apple Account profile lasts seven days, of which a proportional third would
	/// leave barely two; that case gets a fixed two-day window instead. Long-lived imported
	/// identities scale, which avoids nagging about a one-year certificate from day one.
	static let minimumWindow: TimeInterval = 24 * 60 * 60
	static let maximumWindow: TimeInterval = 7 * 24 * 60 * 60
	/// The window used when the issue date is unknown.
	static let assumedWindow: TimeInterval = 2 * 24 * 60 * 60
	/// Share of the credential's lifetime that counts as the window, when it is known.
	static let proportionalShare: Double = 1.0 / 3.0
	/// Point after which an expiring credential becomes `urgent`: the last sixth of the
	/// window, so a two-day window turns urgent on its final eight hours.
	static let urgentShare: Double = 1.0 / 6.0

	static func window(for credential: SigningCredential) -> TimeInterval {
		guard let issuedAt = credential.issuedAt else { return assumedWindow }
		let lifetime = credential.expiresAt.timeIntervalSince(issuedAt)
		guard lifetime > 0 else { return assumedWindow }
		return min(maximumWindow, max(minimumWindow, lifetime * proportionalShare))
	}

	static func plan(for credential: SigningCredential, now: Date = Date()) -> RenewalPlan {
		let expiresAt = credential.effectiveExpiry
		let window = self.window(for: credential)
		let remaining = expiresAt.timeIntervalSince(now)
		let days = Int(floor(remaining / 86_400))
		let renewAfter = expiresAt.addingTimeInterval(-window)

		// Revocation first: it is the one fact a renewal cannot fix, and an identity that
		// was also about to expire should say the thing that makes renewal pointless.
		let status: RenewalStatus
		if credential.isRevoked {
			status = .blocked
		} else if remaining <= 0 {
			// A lapsed identity with no renewal path cannot be repaired by re-signing
			// either; saying "expired" would imply an action that does not exist.
			status = credential.canRenewOnDevice ? .lapsed : .blocked
		} else if remaining > window {
			status = .notDue
		} else if !credential.canRenewOnDevice {
			// Inside the window but nothing here can renew it. Reportable, not scheduled.
			status = .blocked
		} else {
			status = remaining <= window * urgentShare ? .urgent : .due
		}

		return RenewalPlan(
			credentialID: credential.id,
			renewAfter: renewAfter,
			expiresAt: expiresAt,
			window: window,
			daysRemaining: days,
			status: status
		)
	}

	/// Plans for a whole inventory, most urgent first.
	///
	/// Ordering is the UI contract: the row that needs action is the first row. Ties break
	/// on the expiry date, then on the identifier, so the list does not reshuffle between
	/// two renders of the same data.
	static func plans(for credentials: [SigningCredential], now: Date = Date()) -> [RenewalPlan] {
		sorted(credentials.map { plan(for: $0, now: now) })
	}

	/// The ordering, on its own.
	///
	/// Exposed because plans arrive from more than one source — imported certificates and
	/// Apple Account profiles — and merging two lists is only stable if both were sorted by
	/// the same rule. A total order (status, expiry, identifier) means the merge of two
	/// sorted lists is deterministic without a tie-break at the call site.
	static func sorted(_ plans: [RenewalPlan]) -> [RenewalPlan] {
		plans.sorted { lhs, rhs in
			if lhs.status.sortPriority != rhs.status.sortPriority {
				return lhs.status.sortPriority < rhs.status.sortPriority
			}
			if lhs.expiresAt != rhs.expiresAt { return lhs.expiresAt < rhs.expiresAt }
			return lhs.credentialID < rhs.credentialID
		}
	}

	/// The single credential a background pass should renew: the most urgent one that is
	/// actually renewable, or `nil` when there is nothing worth waking up for.
	static func nextAction(from plans: [RenewalPlan]) -> RenewalPlan? {
		plans.first { $0.status.isActionable }
	}
}

private extension RenewalStatus {
	var sortPriority: Int {
		switch self {
		case .lapsed: 0
		case .urgent: 1
		case .due: 2
		case .blocked: 3
		case .unknown: 4
		case .notDue: 5
		}
	}
}
