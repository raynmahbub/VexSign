//
//  InstallDeadlineBudgetTests.swift
//  VexSignTests
//
//  The installer's own deadlines are counted in time the app was running.
//
//  Timed as one sleep, a deadline also ran out while iOS had the app suspended. It then acted the
//  moment the app ran again, ahead of the device check that would have confirmed the install.
//  These tests replay the accounting: what a wait that ran long does to the budget, and that the
//  budget still always ends.
//

import XCTest
@testable import VexSign

final class InstallDeadlineBudgetTests: XCTestCase {
	/// Spends the whole budget, reporting every wait as having taken `elapsed(index, planned)`.
	/// Returns the waits that were planned. Stops after `limit` waits so a budget that never
	/// ended would fail a test instead of hanging it.
	private func drain(
		_ budget: InstallDeadlineBudget,
		limit: Int = 10_000,
		elapsed: (Int, TimeInterval) -> TimeInterval = { _, planned in planned }
	) -> [TimeInterval] {
		var budget = budget
		var waits: [TimeInterval] = []
		while let planned = budget.nextWait, waits.count < limit {
			budget.spend(planned: planned, elapsed: elapsed(waits.count, planned))
			waits.append(planned)
		}
		return waits
	}

	// MARK: Spending

	func testTheBudgetIsSpentInShortWaits() {
		let waits = drain(InstallDeadlineBudget(seconds: 12, step: 5))

		XCTAssertEqual(waits, [5, 5, 2])
		XCTAssertEqual(waits.reduce(0, +), 12, accuracy: 0.000_001)
	}

	func testAWaitThatTookAsLongAsPlannedGrantsNothing() {
		var budget = InstallDeadlineBudget(seconds: 12, step: 5)

		budget.spend(planned: 5, elapsed: 5)
		budget.spend(planned: 5, elapsed: 5.4)

		XCTAssertEqual(budget.remaining, 2, accuracy: 0.000_001)
		XCTAssertEqual(budget.extensionsLeft, 8)
	}

	func testASpentBudgetHasNoNextWait() {
		var budget = InstallDeadlineBudget(seconds: 4, step: 5)
		XCTAssertEqual(budget.nextWait, 4)

		budget.spend(planned: 4, elapsed: 4)

		XCTAssertNil(budget.nextWait)
		XCTAssertEqual(budget.remaining, 0)
	}

	// MARK: Time the app was not running

	/// The case the type exists for: the app is suspended with two seconds of a deadline left
	/// and runs again ten minutes later. The deadline must not act at once.
	func testALongWaitNearTheEndLeavesTheGracePeriod() {
		var budget = InstallDeadlineBudget(seconds: 12, step: 5, overrun: 5, resumeGrace: 15)
		budget.spend(planned: 5, elapsed: 5)
		budget.spend(planned: 5, elapsed: 5)

		budget.spend(planned: 2, elapsed: 600)

		XCTAssertEqual(budget.remaining, 15)
		XCTAssertEqual(budget.extensionsLeft, 7)
		XCTAssertEqual(drain(budget), [5, 5, 5])
	}

	/// Early in a long deadline there is already more left than the grace, so nothing is added
	/// and no extension is used up.
	func testALongWaitWithPlentyLeftChangesNothing() {
		var budget = InstallDeadlineBudget(seconds: 390)

		budget.spend(planned: 5, elapsed: 600)

		XCTAssertEqual(budget.remaining, 385)
		XCTAssertEqual(budget.extensionsLeft, 8)
	}

	/// A main thread that was busy for a few seconds is not a suspension.
	func testAnOverrunWithinTheToleranceIsNotTreatedAsASuspension() {
		var tolerated = InstallDeadlineBudget(seconds: 6, step: 5, overrun: 5, resumeGrace: 15)
		tolerated.spend(planned: 5, elapsed: 10)
		XCTAssertEqual(tolerated.remaining, 1, accuracy: 0.000_001)
		XCTAssertEqual(tolerated.extensionsLeft, 8)

		var suspended = InstallDeadlineBudget(seconds: 6, step: 5, overrun: 5, resumeGrace: 15)
		suspended.spend(planned: 5, elapsed: 10.5)
		XCTAssertEqual(suspended.remaining, 15)
		XCTAssertEqual(suspended.extensionsLeft, 7)
	}

	// MARK: It always ends

	/// Every wait runs long. The grace is granted a fixed number of times and then the budget
	/// runs out anyway: a deadline that could be postponed for ever would not be one.
	func testTheGraceIsGrantedAFixedNumberOfTimes() {
		let budget = InstallDeadlineBudget(seconds: 10, step: 5, overrun: 5, resumeGrace: 15, maximumExtensions: 3)

		let waits = drain(budget) { _, _ in 3_600 }

		// Each long wait tops what is left back up to 15 s, three times: after 5 s with 5 s
		// left, then twice more with 10 s left. After that the last 15 s simply run out.
		XCTAssertEqual(waits, [5, 5, 5, 5, 5, 5])
		XCTAssertEqual(waits.reduce(0, +), 30, accuracy: 0.000_001)
		XCTAssertLessThanOrEqual(waits.reduce(0, +), budget.longestPossible)
	}

	func testNoPatternOfLongWaitsOutlastsTheLongestPossibleRun() {
		let budget = InstallDeadlineBudget(seconds: 390)
		let longest = budget.longestPossible
		XCTAssertEqual(longest, 390 + 8 * 15)

		// Deterministic patterns: every wait long, every other, every seventh, and only the
		// last few.
		let patterns: [(Int, TimeInterval) -> TimeInterval] = [
			{ _, _ in 86_400 },
			{ index, planned in index.isMultiple(of: 2) ? 900 : planned },
			{ index, planned in index.isMultiple(of: 7) ? 61 : planned },
			{ index, planned in index >= 75 ? 10_000 : planned },
		]
		for pattern in patterns {
			let waits = drain(budget, elapsed: pattern)
			XCTAssertLessThanOrEqual(waits.reduce(0, +), longest + 0.000_001)
			XCTAssertLessThan(waits.count, 10_000)
		}
	}

	func testWithoutExtensionsALongWaitNeverAddsTime() {
		let budget = InstallDeadlineBudget(seconds: 12, step: 5, maximumExtensions: 0)

		let waits = drain(budget) { _, _ in 3_600 }

		XCTAssertEqual(waits, [5, 5, 2])
	}

	func testValuesThatAreNotUsableStillGiveABudgetThatEnds() {
		XCTAssertNil(InstallDeadlineBudget(seconds: -1).nextWait)
		XCTAssertNil(InstallDeadlineBudget(seconds: 0).nextWait)
		XCTAssertNil(InstallDeadlineBudget(seconds: .nan).nextWait)
		XCTAssertNil(InstallDeadlineBudget(seconds: .infinity).nextWait)

		// A step of zero would make every wait empty and the loop spin.
		let zeroStep = InstallDeadlineBudget(seconds: 12, step: 0)
		XCTAssertEqual(drain(zeroStep), [5, 5, 2])
		XCTAssertEqual(InstallDeadlineBudget(seconds: 12, maximumExtensions: -4).extensionsLeft, 0)

		// Readings that are not numbers are never taken for a suspension.
		var budget = InstallDeadlineBudget(seconds: 6, step: 5)
		budget.spend(planned: 5, elapsed: .nan)
		budget.spend(planned: .nan, elapsed: 5)
		budget.spend(planned: 0, elapsed: 900)
		XCTAssertEqual(budget.remaining, 1, accuracy: 0.000_001)
		XCTAssertEqual(budget.extensionsLeft, 8)
	}

	// MARK: The deadlines that use it

	/// The backstop has to outlast a watcher that is working, with every extension counted in
	/// its favour: it is the last resort, not a second opinion.
	func testTheMonitoringBackstopStaysLongerThanEveryPhaseLimit() {
		let limits = InstallConfirmation.Limits()
		let budget = InstallDeadlineBudget(seconds: limits.monitoringBackstop)

		XCTAssertGreaterThan(budget.remaining, limits.start + limits.verify + limits.verify)
		XCTAssertEqual(budget.longestPossible, limits.monitoringBackstop + 8 * 15)
	}

	// MARK: Waiting

	func testWaitingReturnsTrueOnceTheBudgetIsSpent() async {
		let finished = await InstallDeadlineBudget.wait(InstallDeadlineBudget(seconds: 0.03, step: 0.01))
		XCTAssertTrue(finished)
	}

	func testWaitingOnAnEmptyBudgetReturnsAtOnce() async {
		let finished = await InstallDeadlineBudget.wait(seconds: 0)
		XCTAssertTrue(finished)
	}

	func testWaitingReturnsFalseWhenCancelled() async {
		let waiting = Task { await InstallDeadlineBudget.wait(seconds: 3_600) }

		waiting.cancel()
		let finished = await waiting.value

		XCTAssertFalse(finished)
	}
}
