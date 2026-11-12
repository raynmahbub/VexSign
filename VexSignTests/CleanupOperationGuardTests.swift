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

func testTheRegistryIsIdleUntilSomethingIsAcquired() async {
        XCTAssertFalse(await AppOperationRegistry().hasActiveOperations)
    }

    func testTheRegistryStaysActiveUntilTheLastLeaseIsReleased() async throws {
        let registry = AppOperationRegistry()
        var signing: AppOperationRegistry.Lease? = try await registry.acquire("imported:one")
        var installing: AppOperationRegistry.Lease? = try await registry.acquire("signed:two")
        XCTAssertTrue(await registry.hasActiveOperations)

        XCTAssertNotNil(signing)
        signing = nil
        XCTAssertTrue(await registry.hasActiveOperations, "One operation finishing does not free the directory for the other")

        XCTAssertNotNil(installing)
        installing = nil
        XCTAssertFalse(await registry.hasActiveOperations)
    }

    func testAnOperationWithoutAStoredCopyStillCounts() async throws {
        let registry = AppOperationRegistry()
        var anonymous: AppOperationRegistry.Lease? = try await registry.acquire(nil)
        XCTAssertTrue(await registry.hasActiveOperations)

        XCTAssertNotNil(anonymous)
        anonymous = nil
        XCTAssertFalse(await registry.hasActiveOperations)
    }

    func testARefusedAcquireLeavesNothingBehind() async throws {
        let registry = AppOperationRegistry()
        var owner: AppOperationRegistry.Lease? = try await registry.acquire("signed:one")
        await XCTAssertThrowsError(try await registry.acquire("signed:one"))

        XCTAssertNotNil(owner)
        owner = nil
        XCTAssertFalse(await registry.hasActiveOperations, "A refused request must not look like a running operation")
    }

    @MainActor
    func testStaleLeftoverSelectionMustStillBelongToAnOrphan() {
        let old = URL(fileURLWithPath: "/tmp/library/old")
        let sibling = URL(fileURLWithPath: "/tmp/library/old-other")
        XCTAssertTrue(StorageManager.isWithinCurrentLeftovers(old.appendingPathComponent("child"), [old]))
        XCTAssertFalse(StorageManager.isWithinCurrentLeftovers(sibling, [old]))
        XCTAssertFalse(StorageManager.isWithinCurrentLeftovers(old, []))
    }

    func testTemporaryWorkerBlocksCleanupAndCannotStartDuringCleanup() async throws {
        let registry = AppOperationRegistry()
        var worker: AppOperationRegistry.Lease? = try await registry.acquireTemporaryWork()
        XCTAssertNil(await registry.acquireCleanup())
        XCTAssertNotNil(worker)
        worker = nil
        var cleanup = await registry.acquireCleanup()
        XCTAssertNotNil(cleanup)
        await XCTAssertThrowsError(try await registry.acquireTemporaryWork())
        cleanup = nil
        XCTAssertNoThrow(try await registry.acquireTemporaryWork())
    }

    func testCleanupAndOperationsExcludeEachOtherUntilTheirLeasesEnd() async throws {
        let registry = AppOperationRegistry()
        var operation: AppOperationRegistry.Lease? = try await registry.acquire("one")
        XCTAssertNil(await registry.acquireCleanup())
        XCTAssertNotNil(operation)
        operation = nil
        var cleanup = await registry.acquireCleanup()
        XCTAssertNotNil(cleanup)
        XCTAssertNil(await registry.acquireCleanup())
        await XCTAssertThrowsError(try await registry.acquire("two"))
        cleanup = nil
        XCTAssertNoThrow(try await registry.acquire("two"))
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

    func testAClaimIsNotAnOperationOnAStoredCopy() async throws {
        let registry = AppOperationRegistry()
        let claim = registry.claimProduction(of: "new-copy")
        registry.confirmProduction(of: "new-copy")

        XCTAssertFalse(await registry.hasActiveOperations, "Producing a copy does not hold up a cleanup pass by itself")
        XCTAssertFalse(registry.isBusy("signed:new-copy"))
        // Once the copy is registered, the next operation can own it straight away.
        XCTAssertNoThrow(try await registry.acquire("signed:new-copy"))
        withExtendedLifetime(claim) {}
    }

    func testAnOperationOnAStoredCopyIsNotAClaim() async throws {
        let registry = AppOperationRegistry()
        let lease = try await registry.acquire("signed:one")

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

final class TemporaryCleanupPolicyTests: XCTestCase {
    func testRetentionAppliesToRootItemAndDescendantsButNotLookalikes() {
        let root = URL(fileURLWithPath: "/tmp/vex-policy-test", isDirectory: true)
        let staging = root.appendingPathComponent("VexSignDownloads", isDirectory: true)
        let retained = ["VexSignTweak_123", "VexSignTweakExtract_123", "VexSignZipExtract_123",
                        "VexSignSharedTweak_123", "TweakAnalyze_123", "VexBackupOut_123", "VexSignDownloads"]
        for name in retained {
            let folder = root.appendingPathComponent(name)
            XCTAssertTrue(TemporaryCleanupPolicy.isRetained(folder, temporaryRoot: root, downloadStaging: staging), name)
            XCTAssertTrue(TemporaryCleanupPolicy.isRetained(folder.appendingPathComponent("child"), temporaryRoot: root, downloadStaging: staging), name)
        }
        for name in ["VexSignTweaker_123", "VexBackupOutside_123", "VexSignDownloads-other", "ordinary"] {
            XCTAssertFalse(TemporaryCleanupPolicy.isRetained(root.appendingPathComponent(name), temporaryRoot: root, downloadStaging: staging), name)
        }
        XCTAssertFalse(TemporaryCleanupPolicy.isRetained(root.deletingLastPathComponent().appendingPathComponent("VexSignTweak_123"), temporaryRoot: root, downloadStaging: staging))
    }

    func testStaleSweepDoesNotUseAgeAsProofOfIdleOrDeleteRetainedOutput() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let old = root.appendingPathComponent("VexSigning_old")
        let export = root.appendingPathComponent("VexBackupOut_old")
        for item in [old, export] {
            try fm.createDirectory(at: item, withIntermediateDirectories: true)
            try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: item.path)
        }
        let registry = AppOperationRegistry()
        var worker: AppOperationRegistry.Lease? = try await registry.acquireTemporaryWork()
        XCTAssertEqual(TempStorageSweeper.sweep(maxAge: 1, temporaryRoot: root, registry: registry), 0)
        XCTAssertTrue(fm.fileExists(atPath: old.path))
        XCTAssertNotNil(worker)
        worker = nil
        XCTAssertEqual(TempStorageSweeper.sweep(maxAge: 1, temporaryRoot: root, registry: registry), 1)
        XCTAssertFalse(fm.fileExists(atPath: old.path))
        XCTAssertTrue(fm.fileExists(atPath: export.path))
    }
}
