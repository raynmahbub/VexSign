//
//  CleanupOperationGuardTests.swift
//  VexSignTests
//
//  Cleanup and the files of an operation that is still running.
//
//  Signing and installation keep their work in the temporary directory. A cleanup pass that ran
//  because one operation had finished cleared that directory for all of them: the others then
//  stopped part-way on a file that had just been there. A pass that removed leftovers could do
//  worse: a copy that is being produced is a folder with no row until it is registered, so its
//  bundle was deleted just before the row that points at it was written.
//
//  A pass now asks whether anything is still running, and what is being produced. These tests
//  pin both questions and what a pass does with the answers.
//

import Foundation
import XCTest
@testable import VexSign

final class CleanupOperationGuardTests: XCTestCase {
	// MARK: - Is anything running?

	func testTheRegistryIsIdleUntilSomethingIsAcquired() {
		XCTAssertFalse(AppOperationRegistry().hasActiveOperations)
	}

	func testTheRegistryStaysActiveUntilTheLastLeaseIsReleased() throws {
		let registry = AppOperationRegistry()
		var signing: AppOperationRegistry.Lease? = try registry.acquire("imported:one")
		var installing: AppOperationRegistry.Lease? = try registry.acquire("signed:two")
		XCTAssertTrue(registry.hasActiveOperations)

		XCTAssertNotNil(signing)
		signing = nil
		XCTAssertTrue(registry.hasActiveOperations, "One operation finishing does not free the directory for the other")

		XCTAssertNotNil(installing)
		installing = nil
		XCTAssertFalse(registry.hasActiveOperations)
	}

	func testAnOperationWithoutAStoredCopyStillCounts() throws {
		let registry = AppOperationRegistry()
		var anonymous: AppOperationRegistry.Lease? = try registry.acquire(nil)
		XCTAssertTrue(registry.hasActiveOperations)

		XCTAssertNotNil(anonymous)
		anonymous = nil
		XCTAssertFalse(registry.hasActiveOperations)
	}

	func testARefusedAcquireLeavesNothingBehind() throws {
		let registry = AppOperationRegistry()
		var owner: AppOperationRegistry.Lease? = try registry.acquire("signed:one")
		XCTAssertThrowsError(try registry.acquire("signed:one"))

		XCTAssertNotNil(owner)
		owner = nil
		XCTAssertFalse(registry.hasActiveOperations, "A refused request must not look like a running operation")
	}

	// MARK: - What is being produced?

	func testACopyIsKnownFromTheMomentItIsAnnounced() {
		let registry = AppOperationRegistry()
		XCTAssertFalse(registry.knowsProduction(of: "new-copy"))

		let claim = registry.claimProduction(of: "new-copy")

		XCTAssertTrue(registry.knowsProduction(of: "new-copy"))
		XCTAssertFalse(registry.knowsProduction(of: "another-copy"))
		withExtendedLifetime(claim) {}
	}

	func testAClaimGivenUpWithoutARowEndsWithTheRun() {
		let registry = AppOperationRegistry()
		var claim: AppOperationRegistry.Lease? = registry.claimProduction(of: "abandoned")
		XCTAssertTrue(registry.knowsProduction(of: "abandoned"))

		// A run that fails or is cancelled never confirms.
		XCTAssertNotNil(claim)
		claim = nil

		XCTAssertFalse(registry.knowsProduction(of: "abandoned"), "What it left behind is a leftover like any other")
	}

	func testARegisteredCopyStaysKnownAfterItsRunIsOver() {
		let registry = AppOperationRegistry()
		var claim: AppOperationRegistry.Lease? = registry.claimProduction(of: "new-copy")
		registry.confirmProduction(of: "new-copy")

		XCTAssertNotNil(claim)
		claim = nil

		XCTAssertTrue(
			registry.knowsProduction(of: "new-copy"),
			"A pass that read the library before the row was committed has only this to go by"
		)
	}

	func testTwoClaimsOnOneCopyNeedBothGivenUp() {
		let registry = AppOperationRegistry()
		var first: AppOperationRegistry.Lease? = registry.claimProduction(of: "new-copy")
		var second: AppOperationRegistry.Lease? = registry.claimProduction(of: "new-copy")

		XCTAssertNotNil(first)
		first = nil
		XCTAssertTrue(registry.knowsProduction(of: "new-copy"), "One holder letting go does not speak for the other")

		XCTAssertNotNil(second)
		second = nil
		XCTAssertFalse(registry.knowsProduction(of: "new-copy"))
	}

	func testAClaimIsNotAnOperationOnAStoredCopy() throws {
		let registry = AppOperationRegistry()
		let claim = registry.claimProduction(of: "new-copy")
		registry.confirmProduction(of: "new-copy")

		XCTAssertFalse(registry.hasActiveOperations, "Producing a copy does not hold up a cleanup pass by itself")
		XCTAssertFalse(registry.isBusy("signed:new-copy"))
		// Once the copy is registered, the next operation can own it straight away.
		XCTAssertNoThrow(try registry.acquire("signed:new-copy"))
		withExtendedLifetime(claim) {}
	}

	func testAnOperationOnAStoredCopyIsNotAClaim() throws {
		let registry = AppOperationRegistry()
		let lease = try registry.acquire("signed:one")

		XCTAssertFalse(registry.knowsProduction(of: "one"), "Being signed from, installed or deleted is not being produced")
		withExtendedLifetime(lease) {}
	}

	// MARK: - What a pass may clear

	func testAPassLeavesTheTemporaryDirectoryAndLeftoversAloneWhileAnOperationRuns() {
		let enabled: [StorageCategory] = [.caches, .temporary, .leftovers, .archives]

		let plan = CleanupPassPolicy.plan(enabled, operationsActive: true)

		XCTAssertEqual(plan.clear, [.caches, .archives], "Everything else the user enabled is still cleared, in the same order")
		XCTAssertEqual(plan.deferred, [.temporary, .leftovers], "And what waits is named, so it can be said")
	}

	func testAPassClearsEverythingEnabledOnceNothingIsRunning() {
		let enabled: [StorageCategory] = [.caches, .temporary, .leftovers, .archives]

		let plan = CleanupPassPolicy.plan(enabled, operationsActive: false)

		XCTAssertEqual(plan.clear, enabled)
		XCTAssertEqual(plan.deferred, [])
	}

	func testTheGuardNeverAddsACategoryTheUserDidNotEnable() {
		for active in [true, false] {
			let nothing = CleanupPassPolicy.plan([], operationsActive: active)
			XCTAssertEqual(nothing.clear, [])
			XCTAssertEqual(nothing.deferred, [])
		}

		XCTAssertEqual(CleanupPassPolicy.plan([.temporary], operationsActive: true).clear, [])
		XCTAssertEqual(CleanupPassPolicy.plan([.leftovers], operationsActive: true).clear, [])
		XCTAssertEqual(CleanupPassPolicy.plan([.caches], operationsActive: true).clear, [.caches])
		XCTAssertEqual(CleanupPassPolicy.plan([.caches], operationsActive: true).deferred, [])
	}

	func testNothingAskedForIsLost() {
		let requested: [StorageCategory] = [.archives, .leftovers, .logs, .temporary, .caches]

		for active in [true, false] {
			let plan = CleanupPassPolicy.plan(requested, operationsActive: active)
			XCTAssertEqual(Set(plan.clear + plan.deferred), Set(requested))
			XCTAssertEqual(plan.clear.count + plan.deferred.count, requested.count)
		}
	}

	func testOnlyTheTwoAreasARunningOperationUsesAreDeferred() {
		XCTAssertEqual(Set(CleanupPassPolicy.deferredWhileOperating), [.temporary, .leftovers])
	}
}
