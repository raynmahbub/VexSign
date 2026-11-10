//
//  CleanupOperationGuardTests.swift
//  VexSignTests
//
//  Automatic cleanup and the files of an operation that is still running.
//
//  Signing and installation keep their work in the temporary directory. A cleanup pass that ran
//  because one operation had finished cleared that directory for all of them: the others then
//  stopped part-way on a file that had just been there. The pass now asks whether anything is
//  still running, and these tests pin both halves of that question.
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

	// MARK: - What an automatic pass may clear

	func testAnAutomaticPassLeavesTheTemporaryDirectoryAloneWhileAnOperationRuns() {
		let enabled: [StorageCategory] = [.caches, .temporary, .leftovers, .archives]

		XCTAssertEqual(
			CleanupManager.automaticCategories(enabled, operationsActive: true),
			[.caches, .leftovers, .archives],
			"Everything else the user enabled is still cleared, in the same order"
		)
	}

	func testAnAutomaticPassClearsEverythingEnabledOnceNothingIsRunning() {
		let enabled: [StorageCategory] = [.caches, .temporary, .leftovers, .archives]

		XCTAssertEqual(CleanupManager.automaticCategories(enabled, operationsActive: false), enabled)
	}

	func testTheGuardNeverAddsACategoryTheUserDidNotEnable() {
		XCTAssertEqual(CleanupManager.automaticCategories([], operationsActive: true), [])
		XCTAssertEqual(CleanupManager.automaticCategories([], operationsActive: false), [])
		XCTAssertEqual(CleanupManager.automaticCategories([.temporary], operationsActive: true), [])
		XCTAssertEqual(CleanupManager.automaticCategories([.caches], operationsActive: true), [.caches])
	}
}
