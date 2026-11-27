//
//  AppOperationRegistryConcurrencyTests.swift
//  VexSignTests
//
//  The registry is the one place that decides which operation owns a stored copy. These
//  cover the property the single-threaded tests cannot: contended callers.
//

import Dispatch
import Foundation
import XCTest
@testable import VexSign

final class AppOperationRegistryConcurrencyTests: XCTestCase {
	/// Collects results from concurrent callers without relying on the code under test.
	private final class Box: @unchecked Sendable {
		private let lock = NSLock()
		private var leases: [AppOperationRegistry.Lease] = []
		private var refusals = 0

		func keep(_ lease: AppOperationRegistry.Lease) { lock.lock(); leases.append(lease); lock.unlock() }
		func refuse() { lock.lock(); refusals += 1; lock.unlock() }
		var counts: (held: Int, refused: Int) { lock.lock(); defer { lock.unlock() }; return (leases.count, refusals) }
		func releaseAll() { lock.lock(); leases.removeAll(); lock.unlock() }
	}

	func testContendedCallersForOneCopyProduceExactlyOneOwner() {
		let registry = AppOperationRegistry()
		let box = Box()

		DispatchQueue.concurrentPerform(iterations: 64) { _ in
			do { box.keep(try registry.acquire("signed:contended")) } catch { box.refuse() }
		}

		XCTAssertEqual(box.counts.held, 1)
		XCTAssertEqual(box.counts.refused, 63)
		XCTAssertTrue(registry.isBusy("signed:contended"))

		box.releaseAll()
		XCTAssertFalse(registry.isBusy("signed:contended"))
		XCTAssertFalse(registry.hasActiveOperations)
	}

	func testContendedCallersForDifferentCopiesAllProceed() {
		let registry = AppOperationRegistry()
		let box = Box()

		DispatchQueue.concurrentPerform(iterations: 64) { index in
			do { box.keep(try registry.acquire("signed:\(index)")) } catch { box.refuse() }
		}

		XCTAssertEqual(box.counts.held, 64)
		XCTAssertEqual(box.counts.refused, 0)
		// Cleanup stays out while any of them is held, and gets in once they are gone.
		XCTAssertNil(registry.acquireCleanup())
		box.releaseAll()
		XCTAssertNotNil(registry.acquireCleanup())
	}

	func testCleanupAndWorkNeverHoldTheRegistryTogether() {
		let registry = AppOperationRegistry()
		let box = Box()
		let cleanups = Box()

		DispatchQueue.concurrentPerform(iterations: 200) { index in
			if index % 2 == 0 {
				if let lease = registry.acquireCleanup() {
					// While cleanup holds the registry nothing else may be registered.
					XCTAssertFalse(registry.hasActiveOperations)
					cleanups.keep(lease)
					cleanups.releaseAll()
				}
			} else {
				do {
					let lease = try registry.acquire("imported:\(index)")
					XCTAssertNil(registry.acquireCleanup())
					box.keep(lease)
				} catch {
					box.refuse()
				}
			}
		}

		box.releaseAll()
		XCTAssertFalse(registry.hasActiveOperations)
		XCTAssertNotNil(registry.acquireCleanup())
	}

	func testProductionAcquiredBeforeCleanupBlocksCleanupUntilRelease() throws {
		let registry = AppOperationRegistry()
		let production = try registry.claimProduction(of: "copy")

		XCTAssertNil(registry.acquireCleanup())
		production.release()
		let cleanup = try XCTUnwrap(registry.acquireCleanup())
		withExtendedLifetime(cleanup) {}
	}

	func testCleanupAcquiredBeforeProductionRejectsProductionUntilRelease() throws {
		let registry = AppOperationRegistry()
		let cleanup = try XCTUnwrap(registry.acquireCleanup())

		XCTAssertThrowsError(try registry.claimProduction(of: "copy")) { error in
			XCTAssertTrue(error is AppOperationRegistry.Busy)
		}
		cleanup.release()
		let production = try registry.claimProduction(of: "copy")
		withExtendedLifetime(production) {}
	}

	func testSimultaneousCleanupAndProductionAdmissionHasExactlyOneWinner() {
		let registry = AppOperationRegistry()
		let winners = Box()
		let ready = DispatchGroup()
		let finished = DispatchGroup()
		let start = DispatchSemaphore(value: 0)
		let queue = DispatchQueue(label: "AppOperationRegistryAdmission", attributes: .concurrent)

		for operation in 0..<2 {
			ready.enter()
			finished.enter()
			queue.async {
				ready.leave()
				start.wait()
				if operation == 0 {
					do { winners.keep(try registry.claimProduction(of: "copy")) }
					catch { winners.refuse() }
				} else if let cleanup = registry.acquireCleanup() {
					winners.keep(cleanup)
				} else {
					winners.refuse()
				}
				finished.leave()
			}
		}

		ready.wait()
		start.signal()
		start.signal()
		finished.wait()
		XCTAssertEqual(winners.counts.held, 1)
		XCTAssertEqual(winners.counts.refused, 1)

		winners.releaseAll()
		let nextCleanup = registry.acquireCleanup()
		XCTAssertNotNil(nextCleanup)
		withExtendedLifetime(nextCleanup) {}
	}

	func testMultipleProductionOwnersBlockCleanupUntilTheLastRelease() throws {
		let registry = AppOperationRegistry()
		let first = try registry.claimProduction(of: "copy")
		let second = try registry.claimProduction(of: "copy")
		let other = try registry.claimProduction(of: "other")

		first.release()
		second.release()
		XCTAssertNil(registry.acquireCleanup())
		other.release()
		let cleanup = registry.acquireCleanup()
		XCTAssertNotNil(cleanup)
		withExtendedLifetime(cleanup) {}
	}

	func testLeaseReleaseIsIdempotentAndAllowsSubsequentAdmission() throws {
		let registry = AppOperationRegistry()
		let production = try registry.claimProduction(of: "copy")
		production.release()
		production.release()

		let cleanup = try XCTUnwrap(registry.acquireCleanup())
		cleanup.release()
		cleanup.release()
		let next = try registry.claimProduction(of: "next")
		withExtendedLifetime(next) {}
	}

	func testCancelledProductionAdmissionLeavesNoClaim() async {
		let registry = AppOperationRegistry()
		let wasCancelled = await Task { () -> Bool in
			withUnsafeCurrentTask { task in task?.cancel() }
			do {
				let lease = try registry.claimProduction(of: "cancelled")
				withExtendedLifetime(lease) {}
				return false
			} catch is CancellationError {
				return true
			} catch {
				return false
			}
		}.value

		XCTAssertTrue(wasCancelled)
		XCTAssertFalse(registry.knowsProduction(of: "cancelled"))
		let cleanup = registry.acquireCleanup()
		XCTAssertNotNil(cleanup)
		withExtendedLifetime(cleanup) {}
	}

	func testAProductionClaimGivenUpWithoutConfirmationIsForgotten() throws {
		let registry = AppOperationRegistry()
		var first: AppOperationRegistry.Lease? = try registry.claimProduction(of: "copy")
		var second: AppOperationRegistry.Lease? = try registry.claimProduction(of: "copy")
		XCTAssertTrue(registry.knowsProduction(of: "copy"))

		first = nil
		XCTAssertTrue(registry.knowsProduction(of: "copy"), "one claim is still held")
		second = nil
		XCTAssertFalse(registry.knowsProduction(of: "copy"))
		_ = (first, second)

		// Confirmed copies stay known after their claim is released.
		var confirmed: AppOperationRegistry.Lease? = try registry.claimProduction(of: "kept")
		registry.confirmProduction(of: "kept")
		confirmed = nil
		_ = confirmed
		XCTAssertTrue(registry.knowsProduction(of: "kept"))
	}
}
