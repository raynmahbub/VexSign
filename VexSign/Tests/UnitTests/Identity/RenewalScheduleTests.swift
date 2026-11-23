//
//  RenewalScheduleTests.swift
//  VexSignTests
//
//  When a signed app stops working, and what the app is allowed to say about it.
//
//  The date this file pins is the one users hit: a free Apple Account profile lasts
//  seven days. Boundaries are asserted from both sides, because an off-by-one in a day
//  counter reads as "expires tomorrow" on the day it already expired.
//

import XCTest
@testable import VexSign

final class RenewalScheduleTests: XCTestCase {
	private let now = Date(timeIntervalSince1970: 1_800_000_000)
	private func days(_ count: Double) -> TimeInterval { count * 86_400 }
	private func at(_ offset: TimeInterval) -> Date { now.addingTimeInterval(offset) }

	private func credential(
		id: String = "cert-1",
		kind: SigningCredentialKind = .appleAccount,
		expiresIn offset: TimeInterval,
		issuedDaysAgo: Double? = nil,
		certificateExpiresIn: TimeInterval? = nil,
		revoked: Bool = false,
		renewable: Bool = true
	) -> SigningCredential {
		SigningCredential(
			id: id,
			kind: kind,
			name: "Personal Team",
			teamID: "TEAM123456",
			expiresAt: at(offset),
			certificateExpiresAt: certificateExpiresIn.map { at($0) },
			issuedAt: issuedDaysAgo.map { at(-days($0)) },
			isRevoked: revoked,
			canRenewOnDevice: renewable
		)
	}

	// MARK: - The seven-day profile

	func testSevenDayProfileIsDueOnItsFifthDay() {
		// Issued 5 days ago, valid 7: lifetime 7 days → window 7/3 ≈ 2.33 days.
		let plan = RenewalPlanner.plan(for: credential(expiresIn: days(2), issuedDaysAgo: 5), now: now)
		XCTAssertEqual(plan.status, .due)
		XCTAssertEqual(plan.daysRemaining, 2)
		XCTAssertEqual(plan.window, days(7) / 3, accuracy: 1)
	}

	func testSevenDayProfileIsNotDueOnItsFirstDay() {
		let plan = RenewalPlanner.plan(for: credential(expiresIn: days(6), issuedDaysAgo: 1), now: now)
		XCTAssertEqual(plan.status, .notDue)
	}

	func testSevenDayProfileTurnsUrgentInItsFinalHours() {
		// The last sixth of a ~2.33 day window is under ten hours.
		let plan = RenewalPlanner.plan(for: credential(expiresIn: 6 * 3600, issuedDaysAgo: 6.75), now: now)
		XCTAssertEqual(plan.status, .urgent)
		XCTAssertTrue(plan.status.requiresAttention)
	}

	// MARK: - Windows are bounded

	func testUnknownIssueDateUsesTheAssumedWindow() {
		let plan = RenewalPlanner.plan(for: credential(expiresIn: days(1)), now: now)
		XCTAssertEqual(plan.window, RenewalPlanner.assumedWindow)
		XCTAssertEqual(plan.status, .due)
	}

	func testYearLongIdentityIsNotNaggedFromDayOne() {
		// A one-year profile would scale to a ~121-day window; capped at seven.
		let plan = RenewalPlanner.plan(
			for: credential(kind: .importedPair, expiresIn: days(200), issuedDaysAgo: 165),
			now: now
		)
		XCTAssertEqual(plan.window, RenewalPlanner.maximumWindow)
		XCTAssertEqual(plan.status, .notDue)
	}

	func testWindowNeverFallsBelowOneDay() {
		// Lifetime far shorter than the minimum window must not shrink it.
		let plan = RenewalPlanner.plan(
			for: credential(kind: .importedPair, expiresIn: days(0.5), issuedDaysAgo: 0.0035),
			now: now
		)
		XCTAssertEqual(plan.window, RenewalPlanner.minimumWindow)
	}

	// MARK: - The certificate can expire before the profile

	func testEarlierCertificateExpiryDrivesThePlan() {
		let plan = RenewalPlanner.plan(
			for: credential(expiresIn: days(200), issuedDaysAgo: 300, certificateExpiresIn: days(1)),
			now: now
		)
		XCTAssertEqual(plan.expiresAt, at(days(1)))
		XCTAssertEqual(plan.daysRemaining, 1)
		// The profile's window is capped at seven days, and one day left is inside its
		// final sixth — the same rule that makes a two-day window urgent on its last
		// eight hours. What this test pins is which date drives the plan, so the status
		// is asserted rather than left to drift.
		XCTAssertEqual(plan.status, .urgent)
	}

	func testLapsedProfileIsLapsedNotDue() {
		let plan = RenewalPlanner.plan(for: credential(expiresIn: -days(2), issuedDaysAgo: 9), now: now)
		XCTAssertEqual(plan.status, .lapsed)
		XCTAssertEqual(plan.daysRemaining, -2)
	}

	// MARK: - Honesty about what cannot be done

	func testRevocationBlocksRenewalEvenWhenTimeRemains() {
		let plan = RenewalPlanner.plan(for: credential(expiresIn: days(200), revoked: true), now: now)
		XCTAssertEqual(plan.status, .blocked)
		// Revocation is not scheduled work: a background pass must not try.
		XCTAssertNil(RenewalPlanner.nextAction(from: [plan]))
	}

	func testNonRenewableCredentialInsideWindowIsBlocked() {
		let plan = RenewalPlanner.plan(
			for: credential(kind: .cloud, expiresIn: days(1), renewable: false),
			now: now
		)
		XCTAssertEqual(plan.status, .blocked)
		XCTAssertFalse(plan.status.requiresAttention)
		XCTAssertFalse(plan.status.isActionable)
	}

	func testLapsedCredentialWithoutKeyIsBlockedRatherThanLapsed() {
		// A lapsed identity with no renewal path cannot be repaired by re-signing; saying
		// "expired" would imply an action that does not exist.
		let plan = RenewalPlanner.plan(
			for: credential(kind: .importedPair, expiresIn: -days(1), renewable: false),
			now: now
		)
		XCTAssertEqual(plan.status, .blocked)
	}

	// MARK: - Ordering is the UI contract

	func testPlansAreOrderedMostUrgentFirst() {
		let credentials = [
			credential(id: "notDue", kind: .importedPair, expiresIn: days(300), issuedDaysAgo: 100),
			credential(id: "lapsed", expiresIn: -days(2)),
			credential(id: "due", expiresIn: days(1)),
			credential(id: "blocked", kind: .cloud, expiresIn: days(30), revoked: true, renewable: false),
		]
		let plans = RenewalPlanner.plans(for: credentials, now: now)
		XCTAssertEqual(plans.map(\.credentialID), ["lapsed", "due", "blocked", "notDue"])
		XCTAssertEqual(RenewalPlanner.nextAction(from: plans)?.credentialID, "due")
	}

	func testEqualPlansKeepAStableOrder() {
		let a = credential(id: "b", expiresIn: days(1))
		let b = credential(id: "a", expiresIn: days(1))
		XCTAssertEqual(RenewalPlanner.plans(for: [a, b], now: now).map(\.credentialID), ["a", "b"])
		XCTAssertEqual(RenewalPlanner.plans(for: [b, a], now: now).map(\.credentialID), ["a", "b"])
	}

	func testNextActionIgnoresWorkThatCannotSucceed() {
		let blocked = credential(id: "x", kind: .cloud, expiresIn: days(1), revoked: true, renewable: false)
		XCTAssertNil(RenewalPlanner.nextAction(from: RenewalPlanner.plans(for: [blocked], now: now)))
		XCTAssertNil(RenewalPlanner.nextAction(from: []))
	}

	// MARK: - Progress without division by zero

	func testElapsedFractionIsClampedAndDefined() {
		let plan = RenewalPlanner.plan(for: credential(expiresIn: days(1), issuedDaysAgo: 6), now: now)
		let half = plan.elapsedFraction(now: plan.renewAfter.addingTimeInterval(plan.window / 2))
		XCTAssertEqual(half ?? -1, 0.5, accuracy: 0.001)
		XCTAssertEqual(plan.elapsedFraction(now: at(-days(30))) ?? -1, 0)
		XCTAssertEqual(plan.elapsedFraction(now: at(days(30))) ?? -1, 1)
	}

	// MARK: - The credential boundary

	func testRecordWithoutAProfileDateIsNotSilentlyTreatedAsHealthy() {
		let record = CertificateRecord(
			id: "row-1",
			uuid: "uuid-1",
			nickname: "Work team",
			date: nil,
			expiration: nil,
			isDefault: false,
			ppQCheck: true,
			revoked: false,
			profile: nil,
			additionalProfilePatterns: []
		)
		let credential = SigningCredential(record: record)
		// `distantPast` is the honest "no date": the planner calls it lapsed rather than
		// inventing a healthy future date for a row whose profile could not be parsed.
		let plan = RenewalPlanner.plan(for: credential, now: now)
		XCTAssertEqual(plan.status, .lapsed)
		XCTAssertEqual(credential.name, "Work team")
	}

	func testRevokedRecordIsNeverRenewable() {
		let record = CertificateRecord(
			id: "row-2",
			uuid: nil,
			nickname: nil,
			date: nil,
			expiration: at(days(100)),
			isDefault: false,
			ppQCheck: false,
			revoked: true,
			profile: nil,
			additionalProfilePatterns: []
		)
		let credential = SigningCredential(record: record, canRenewOnDevice: true)
		XCTAssertFalse(credential.canRenewOnDevice)
		XCTAssertEqual(RenewalPlanner.plan(for: credential, now: now).status, .blocked)
	}

	func testEveryCertificateRowProducesAPlan() {
		let records = [
			CertificateRecord(id: "a", uuid: nil, nickname: "A", date: nil, expiration: at(days(100)),
			                  isDefault: true, ppQCheck: true, revoked: false, profile: nil,
			                  additionalProfilePatterns: []),
			// No dates at all: still planned, so the list and the schedule cannot disagree
			// about which certificates exist.
			CertificateRecord(id: "b", uuid: nil, nickname: "B", date: nil, expiration: nil,
			                  isDefault: false, ppQCheck: true, revoked: false, profile: nil,
			                  additionalProfilePatterns: []),
		]
		let plans = RenewalPlanner.plans(
			for: SigningCredential.credentials(in: .init(certificates: records)),
			now: now
		)
		XCTAssertEqual(Set(plans.map(\.credentialID)), ["a", "b"])
	}

	// MARK: - Coordinator publishes, and only says what it knows

	@MainActor
	func testCoordinatorPublishesAttentionOnlyForRealDeadlines() {
		let coordinator = RenewalScheduleCoordinator.shared
		coordinator.reset()
		defer { coordinator.reset() }

		coordinator.refresh(credentials: [credential(expiresIn: days(300), issuedDaysAgo: 60)], now: now)
		XCTAssertTrue(coordinator.needingAttention.isEmpty)
		XCTAssertNil(coordinator.attentionItem())

		// Lapsed: the item carries the plan and the name, never a claim of renewal.
		coordinator.refresh(
			credentials: [credential(expiresIn: -days(1))],
			names: ["cert-1": "VexSign Beta"],
			now: now
		)
		XCTAssertEqual(coordinator.lapsed.count, 1)
		let item = coordinator.attentionItem()
		XCTAssertEqual(item?.plan.status, .lapsed)
		XCTAssertEqual(item?.name, "VexSign Beta")
	}

	@MainActor
	func testCoordinatorKeepsThePublishedArrayWhenNothingChanged() {
		let coordinator = RenewalScheduleCoordinator.shared
		coordinator.reset()
		defer { coordinator.reset() }

		let input = [credential(expiresIn: days(3))]
		let first = coordinator.refresh(credentials: input, now: now)
		let second = coordinator.refresh(credentials: input, now: now)
		XCTAssertEqual(first, second)
		XCTAssertEqual(coordinator.plans, second)
		XCTAssertEqual(coordinator.refreshedAt, now)
	}

	// MARK: - Two sources, one schedule

	@MainActor
	func testRefreshingOneSourceDoesNotEraseTheOther() {
		// The bug this guards: the certificate list and the Apple Account pass refresh at
		// different times. A whole-array replace made each one wipe the other's deadlines.
		let coordinator = RenewalScheduleCoordinator.shared
		coordinator.reset()
		defer { coordinator.reset() }

		coordinator.refresh(source: .certificate, credentials: [credential(id: "imported", expiresIn: days(1))], now: now)
		coordinator.refresh(source: .appleAccount, credentials: [credential(id: "apple", expiresIn: -days(1))], now: now)
		XCTAssertEqual(Set(coordinator.plans.map(\.credentialID)), ["imported", "apple"])

		// A later certificate refresh must not drop the Apple Account plan.
		coordinator.refresh(source: .certificate, credentials: [credential(id: "imported", expiresIn: days(1))], now: now)
		XCTAssertEqual(Set(coordinator.plans.map(\.credentialID)), ["imported", "apple"])
		// Most urgent first, regardless of which source published last.
		XCTAssertEqual(coordinator.plans.first?.credentialID, "apple")
	}

	@MainActor
	func testClearingASourceLeavesTheOtherIntact() {
		let coordinator = RenewalScheduleCoordinator.shared
		coordinator.reset()
		defer { coordinator.reset() }

		coordinator.refresh(source: .certificate, credentials: [credential(id: "imported", expiresIn: days(1))], now: now)
		coordinator.refresh(source: .appleAccount, credentials: [credential(id: "apple", expiresIn: -days(1))], now: now)
		coordinator.clear(source: .appleAccount)
		XCTAssertEqual(coordinator.plans.map(\.credentialID), ["imported"])
		// A name from the cleared source is no longer claimable.
		XCTAssertEqual(coordinator.credentialName(for: "apple"), "A signed app")
	}

	@MainActor
	func testCoordinatorUsesAFallbackNameRatherThanAnEmptyOne() {
		let coordinator = RenewalScheduleCoordinator.shared
		coordinator.reset()
		defer { coordinator.reset() }

		coordinator.refresh(credentials: [credential(expiresIn: -days(1))], now: now)
		XCTAssertEqual(coordinator.attentionItem()?.name, "A signed app")
		XCTAssertEqual(coordinator.plan(forCredentialID: "missing"), nil)
	}
}
