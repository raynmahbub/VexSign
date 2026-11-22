//
//  RenewalScheduleCoordinator.swift
//  VexSign
//
//  Owns the live renewal plans for the certificate screen, the Library badges and the
//  background pass. One cache, refreshed from credentials the app already has; this file
//  adds no new survey of certificate material and never reads a `.p12`.
//
//  Why a coordinator and not a computed property: plans are derived from dates that only
//  change when a credential changes, but they are read from several screens and from the
//  background task. Recomputing per row would show "3 days" in one place and "2 days" in
//  another once the clock crossed midnight. The cache is refreshed explicitly and
//  published once.
//
//  It is @MainActor like the rest of the observable layer, and owns no task: the
//  background pass belongs to `BackgroundAutomation`, which already knows how to ask for
//  execution time. Adding a second scheduler here would give the app two of them.
//

import Foundation
import Combine
import OSLog

/// Where a plan came from. Plans arrive from two sources that must not overwrite each
/// other, because they are refreshed by different code at different times.
enum RenewalPlanSource: String, CaseIterable, Sendable {
	/// Certificates the user imported. Refreshed by the certificate list.
	case certificate
	/// Profiles provisioned by a free Apple Account. Refreshed by the background pass.
	case appleAccount
}

@MainActor
final class RenewalScheduleCoordinator: ObservableObject {
	static let shared = RenewalScheduleCoordinator()

	/// The merged, ordered view for the UI. Never assign directly: every write goes through
	/// a source, so one refresh cannot silently erase the other.
	@Published private(set) var plans: [RenewalPlan] = []
	/// Per-source plans. Each refresh replaces exactly one entry.
	private var plansBySource: [RenewalPlanSource: [RenewalPlan]] = [:]
	/// When `plans` was last recomputed. Shown in diagnostics; never used for scheduling.
	@Published private(set) var refreshedAt: Date?

	/// Display names captured at refresh time, so a notification never needs a managed
	/// object. Values only — this cache must be safe to read from a background pass.
	private var namesBySource: [RenewalPlanSource: [String: String]] = [:]

	private init() {}

	// MARK: - Derived buckets

	/// The UI asks for buckets rather than filtering by status, so "needs attention" is
	/// defined once.
	var needingAttention: [RenewalPlan] { plans.filter { $0.status.requiresAttention } }
	var lapsed: [RenewalPlan] { plans.filter { $0.status == .lapsed } }
	var blocked: [RenewalPlan] { plans.filter { $0.status == .blocked } }

	/// The credential a background pass should renew, if any.
	var nextAction: RenewalPlan? { RenewalPlanner.nextAction(from: plans) }

	// MARK: - Refresh

	/// Recompute from the current inventory.
	///
	/// Takes the credentials rather than fetching them: the caller (the certificate
	/// workspace adapter, which reads Core Data) owns that actor hop, so this stays
	/// testable with a plain array and cannot start a fetch from a view body.
	@discardableResult
	func refresh(
		source: RenewalPlanSource = .certificate,
		credentials: [SigningCredential],
		now: Date = Date()
	) -> [RenewalPlan] {
		plansBySource[source] = RenewalPlanner.plans(for: credentials, now: now)
		refreshedAt = now
		return publish()
	}

	/// Refresh and remember display names in one step. Separate from `refresh` so the
	/// planner stays usable with anonymous credentials in tests.
	@discardableResult
	func refresh(
		source: RenewalPlanSource = .certificate,
		credentials: [SigningCredential],
		names: [String: String],
		now: Date = Date()
	) -> [RenewalPlan] {
		namesBySource[source] = names
		let result = refresh(source: source, credentials: credentials, now: now)
		let planCount = result.count
		let action = RenewalPlanner.nextAction(from: result)
		Logger.misc.notice(
			"Renewal schedule refreshed (\(source.rawValue, privacy: .public)): \(planCount) credential(s), next action \(action?.status.rawValue ?? "none", privacy: .public)."
		)
		return result
	}

	/// Merge the sources and publish, but only on a real change.
	///
	/// `@Published` fires on assignment regardless of equality, and every certificate row
	/// observes this object; an unconditional write would redraw the whole list on each
	/// refresh even when nothing moved.
	@discardableResult
	private func publish() -> [RenewalPlan] {
		let next = RenewalPlanner.sorted(plansBySource.values.flatMap { $0 })
		if next != plans {
			plans = next
		}
		return next
	}

	// MARK: - Lookup

	func plan(forCredentialID id: String) -> RenewalPlan? {
		plans.first { $0.credentialID == id }
	}

	/// The display name last seen for a credential, or a neutral fallback. Never empty, so
	/// a notification cannot read as a bug.
	func credentialName(for id: String) -> String {
		for names in namesBySource.values {
			if let name = names[id] { return name }
		}
		return "A signed app"
	}

	/// The one credential worth a notification, with the facts the caller needs to word it.
	///
	/// Returns `nil` when nothing needs attention, so the caller cannot post an empty
	/// notification. The strings are built in the platform layer; this returns data because
	/// the coordinator must stay free of presentation.
	func attentionItem() -> (plan: RenewalPlan, name: String)? {
		guard let plan = plans.first(where: { $0.status.requiresAttention }) else { return nil }
		return (plan, credentialName(for: plan.credentialID))
	}

	/// Forget one source's plans, leaving the other intact. Used when an Apple Account is
	/// signed out: its profiles are gone, the imported certificates are not.
	func clear(source: RenewalPlanSource) {
		plansBySource[source] = nil
		namesBySource[source] = nil
		_ = publish()
	}

	/// Test and sign-out seam: forget everything without touching the credentials.
	func reset() {
		plansBySource = [:]
		namesBySource = [:]
		plans = []
		refreshedAt = nil
	}
}

// MARK: - Renewability state

/// Whether an Apple Account session exists to provision a renewal with.
///
/// A value-only flag, set by the account layer after it inspects the real session. It
/// exists so presentation can ask "can this be renewed?" without naming
/// `NativeSigningManager`, which the architecture ratchet forbids in `Presentation` — and
/// so the answer has exactly one owner instead of each screen probing the session itself.
///
/// Defaults to `false`: an account nobody has signed into cannot provision anything, and
/// guessing `true` would turn every row into a countdown that ends in an error.
@MainActor
final class RenewalRenewabilityState: ObservableObject {
	static let shared = RenewalRenewabilityState()


	@Published private(set) var isAccountSessionReady = false

	private init() {}

	/// Called by the account layer whenever the session state is known. Idempotent.
	///
	/// Written from `NativeSigningManager` itself (on snapshot refresh, backend
	/// init/reconfigure and sign-out) rather than only from the background pass. The pass
	/// runs at most a few times a day, so a foreground-only user would have seen free-account
	/// rows stuck at `blocked` long after signing in — a status that said "you cannot renew
	/// this" to someone who could.
	///
	/// This file deliberately does not name the account manager: the account layer pushes a
	/// value here, and presentation reads only the value.
	func setAccountSessionReady(_ ready: Bool) {
		if isAccountSessionReady != ready {
			isAccountSessionReady = ready
		}
	}

	/// Test seam.
	func reset() { setAccountSessionReady(false) }
}
