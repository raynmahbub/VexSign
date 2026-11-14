//
//  AppOperationRegistryConcurrencyTests.swift
//  VexSignTests
//
//  The registry is the one place that decides which operation owns a stored copy. These
//  cover the property the single-threaded tests cannot: contended callers.
//

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

	func testAProductionClaimGivenUpWithoutConfirmationIsForgotten() {
		let registry = AppOperationRegistry()
		var first: AppOperationRegistry.Lease? = registry.claimProduction(of: "copy")
		var second: AppOperationRegistry.Lease? = registry.claimProduction(of: "copy")
		XCTAssertTrue(registry.knowsProduction(of: "copy"))

		first = nil
		XCTAssertTrue(registry.knowsProduction(of: "copy"), "one claim is still held")
		second = nil
		XCTAssertFalse(registry.knowsProduction(of: "copy"))
		_ = (first, second)

		// Confirmed copies stay known after their claim is released.
		var confirmed: AppOperationRegistry.Lease? = registry.claimProduction(of: "kept")
		registry.confirmProduction(of: "kept")
		confirmed = nil
		_ = confirmed
		XCTAssertTrue(registry.knowsProduction(of: "kept"))
	}
}
