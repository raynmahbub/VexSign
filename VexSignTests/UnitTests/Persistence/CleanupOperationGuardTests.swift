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
        XCTAssertFalse(AppOperationRegistry().hasActiveOperations)
    }

    func testTheRegistryStaysActiveUntilTheLastLeaseIsReleased() async throws {
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

    func testAnOperationWithoutAStoredCopyStillCounts() async throws {
        let registry = AppOperationRegistry()
        var anonymous: AppOperationRegistry.Lease? = try registry.acquire(nil)
        XCTAssertTrue(registry.hasActiveOperations)

        XCTAssertNotNil(anonymous)
        anonymous = nil
        XCTAssertFalse(registry.hasActiveOperations)
    }

    func testARefusedAcquireLeavesNothingBehind() async throws {
        let registry = AppOperationRegistry()
        var owner: AppOperationRegistry.Lease? = try registry.acquire("signed:one")
        XCTAssertThrowsError(try registry.acquire("signed:one"))

        XCTAssertNotNil(owner)
        owner = nil
        XCTAssertFalse(registry.hasActiveOperations, "A refused request must not look like a running operation")
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
        var worker: AppOperationRegistry.Lease? = try registry.acquireTemporaryWork()
        XCTAssertNil(registry.acquireCleanup())
        XCTAssertNotNil(worker)
        worker = nil
        var cleanup = registry.acquireCleanup()
        XCTAssertNotNil(cleanup)
        XCTAssertThrowsError(try registry.acquireTemporaryWork())
        cleanup = nil
        XCTAssertNoThrow(try registry.acquireTemporaryWork())
    }

    func testCleanupAndOperationsExcludeEachOtherUntilTheirLeasesEnd() async throws {
        let registry = AppOperationRegistry()
        var operation: AppOperationRegistry.Lease? = try registry.acquire("one")
        XCTAssertNil(registry.acquireCleanup())
        XCTAssertNotNil(operation)
        operation = nil
        var cleanup = registry.acquireCleanup()
        XCTAssertNotNil(cleanup)
        XCTAssertNil(registry.acquireCleanup())
        XCTAssertThrowsError(try registry.acquire("two"))
        cleanup = nil
        XCTAssertNoThrow(try registry.acquire("two"))
    }

// MARK: - What is being produced?

    func testACopyIsKnownFromTheMomentItIsAnnounced() throws {
        let registry = AppOperationRegistry()
        XCTAssertFalse(registry.knowsProduction(of: "new-copy"))

        let claim = try registry.claimProduction(of: "new-copy")

        XCTAssertTrue(registry.knowsProduction(of: "new-copy"))
        XCTAssertFalse(registry.knowsProduction(of: "another-copy"))
        withExtendedLifetime(claim) {}
    }

    func testAClaimGivenUpWithoutARowEndsWithTheRun() throws {
        let registry = AppOperationRegistry()
        var claim: AppOperationRegistry.Lease? = try registry.claimProduction(of: "abandoned")
        XCTAssertTrue(registry.knowsProduction(of: "abandoned"))

        // A run that fails or is cancelled never confirms.
        XCTAssertNotNil(claim)
        claim = nil

        XCTAssertFalse(registry.knowsProduction(of: "abandoned"), "What it left behind is a leftover like any other")
    }

    func testARegisteredCopyStaysKnownAfterItsRunIsOver() throws {
        let registry = AppOperationRegistry()
        var claim: AppOperationRegistry.Lease? = try registry.claimProduction(of: "new-copy")
        registry.confirmProduction(of: "new-copy")

        XCTAssertNotNil(claim)
        claim = nil

        XCTAssertTrue(
            registry.knowsProduction(of: "new-copy"),
            "A pass that read the library before the row was committed has only this to go by"
        )
    }

    func testTwoClaimsOnOneCopyNeedBothGivenUp() throws {
        let registry = AppOperationRegistry()
        var first: AppOperationRegistry.Lease? = try registry.claimProduction(of: "new-copy")
        var second: AppOperationRegistry.Lease? = try registry.claimProduction(of: "new-copy")

        XCTAssertNotNil(first)
        first = nil
        XCTAssertTrue(registry.knowsProduction(of: "new-copy"), "One holder letting go does not speak for the other")

        XCTAssertNotNil(second)
        second = nil
        XCTAssertFalse(registry.knowsProduction(of: "new-copy"))
    }

    func testAClaimIsNotAnOperationOnAStoredCopy() async throws {
        let registry = AppOperationRegistry()
        let claim = try registry.claimProduction(of: "new-copy")
        registry.confirmProduction(of: "new-copy")

        XCTAssertFalse(registry.hasActiveOperations, "A production claim is not ownership of a stored copy")
        XCTAssertNil(registry.acquireCleanup(), "Cleanup must wait until production releases its files")
        XCTAssertFalse(registry.isBusy("signed:new-copy"))
        // Once the copy is registered, the next operation can own it straight away.
        XCTAssertNoThrow(try registry.acquire("signed:new-copy"))
        withExtendedLifetime(claim) {}
    }

    func testAnOperationOnAStoredCopyIsNotAClaim() async throws {
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

final class PendingInstallCleanupPolicyTests: XCTestCase {
    func testPendingInstallDeletionKeepsEveryUUIDThatDidNotCommit() {
        let staged = ["deleted", "busy", "unavailable", "deleted"]
        XCTAssertEqual(
            PendingInstallCleanupPolicy.remaining(staged, afterDeleting: ["deleted"]),
            ["busy", "unavailable"],
            "A refused batch delete must stay queued for a later flush, without duplicate retry records"
        )
        XCTAssertEqual(PendingInstallCleanupPolicy.remaining(staged, afterDeleting: []), ["deleted", "busy", "unavailable"])
        XCTAssertEqual(
            PendingInstallCleanupPolicy.remaining(staged, afterDeleting: ["deleted"], confirmedMissing: ["unavailable"]),
            ["busy"],
            "A confirmed missing row is already absent; lookup failures must not be represented as missing"
        )
        XCTAssertEqual(PendingInstallCleanupPolicy.remaining(staged, afterDeleting: Set(staged)), [])
    }
}

final class TemporaryCleanupPolicyTests: XCTestCase {
    func testRetentionAppliesToRootItemAndDescendantsButNotLookalikes() {
        let root = URL(fileURLWithPath: "/tmp/vex-policy-test", isDirectory: true)
        let staging = root.appendingPathComponent("VexSignDownloads", isDirectory: true)
        let retained = ["VexSignTweak_123", "VexSignTweakExtract_123", "VexSignZipExtract_123",
                        "VexSignSharedTweak_123", "TweakAnalyze_123", "VexBackupOut_123", "VexSignDownloads", "RemovedItems"]
        for name in retained {
            let folder = root.appendingPathComponent(name)
            XCTAssertTrue(TemporaryCleanupPolicy.isRetained(folder, temporaryRoot: root, downloadStaging: staging), name)
            XCTAssertTrue(TemporaryCleanupPolicy.isRetained(folder.appendingPathComponent("child"), temporaryRoot: root, downloadStaging: staging), name)
        }
        for name in ["VexSignTweaker_123", "VexBackupOutside_123", "VexSignDownloads-other", "RemovedItems-old", "ordinary"] {
            XCTAssertFalse(TemporaryCleanupPolicy.isRetained(root.appendingPathComponent(name), temporaryRoot: root, downloadStaging: staging), name)
        }
        XCTAssertFalse(TemporaryCleanupPolicy.isRetained(root.deletingLastPathComponent().appendingPathComponent("VexSignTweak_123"), temporaryRoot: root, downloadStaging: staging))
    }

    func testUndoRetentionSurvivesSymlinkAliasesToRemovedItems() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("CleanupUndo-" + UUID().uuidString, isDirectory: true)
        let undoRoot = root.appendingPathComponent("RemovedItems", isDirectory: true)
        let staging = root.appendingPathComponent("VexSignDownloads", isDirectory: true)
        try fileManager.createDirectory(at: undoRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let alias = root.appendingPathComponent("undo-alias", isDirectory: true)
        try fileManager.createSymbolicLink(at: alias, withDestinationURL: undoRoot)

        XCTAssertTrue(TemporaryCleanupPolicy.isRetained(undoRoot, temporaryRoot: root, downloadStaging: staging))
        XCTAssertTrue(TemporaryCleanupPolicy.isRetained(undoRoot.appendingPathComponent("held.app"), temporaryRoot: root, downloadStaging: staging))
        XCTAssertTrue(TemporaryCleanupPolicy.isRetained(alias, temporaryRoot: root, downloadStaging: staging))
        XCTAssertTrue(TemporaryCleanupPolicy.isRetained(alias.appendingPathComponent("held.app"), temporaryRoot: root, downloadStaging: staging))
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
        var worker: AppOperationRegistry.Lease? = try registry.acquireTemporaryWork()
        XCTAssertEqual(TempStorageSweeper.sweep(maxAge: 1, temporaryRoot: root, registry: registry), 0)
        XCTAssertTrue(fm.fileExists(atPath: old.path))
        XCTAssertNotNil(worker)
        worker = nil
        XCTAssertEqual(TempStorageSweeper.sweep(maxAge: 1, temporaryRoot: root, registry: registry), 1)
        XCTAssertFalse(fm.fileExists(atPath: old.path))
        XCTAssertTrue(fm.fileExists(atPath: export.path))
    }

    // MARK: - Storage model value semantics (what cleanup may touch and how it is reported)

    func testCategoryBrowseAndExploreFlagsFollowTheUXContract() {
        // Tweaks and certificates are never browsable; the app-holding categories are never
        // explorable. These gate which storage screens a user can open, so they are pinned.
        XCTAssertFalse(StorageCategory.tweaks.isBrowsable)
        XCTAssertFalse(StorageCategory.certificates.isBrowsable)
        XCTAssertTrue(StorageCategory.signed.isBrowsable)
        XCTAssertTrue(StorageCategory.caches.isBrowsable)

        XCTAssertFalse(StorageCategory.signed.allowsExploring)
        XCTAssertFalse(StorageCategory.imported.allowsExploring)
        XCTAssertFalse(StorageCategory.archives.allowsExploring)
        XCTAssertTrue(StorageCategory.tweaks.allowsExploring)
        XCTAssertTrue(StorageCategory.caches.allowsExploring)
    }

    func testSafeToClearIsExactlyTheRegenerableCategories() {
        // Only regenerable data is auto-clearable; user content and identities never are.
        XCTAssertEqual(Set(StorageCategory.safeToClear), Set([.caches, .logs, .temporary, .leftovers]))
        for category in [StorageCategory.signed, .imported, .archives, .tweaks, .certificates, .other] {
            XCTAssertFalse(StorageCategory.safeToClear.contains(category), "\(category.rawValue) must not be auto-cleared")
        }
    }

    func testUsageIsEmptyFollowsCountNotSize() {
        XCTAssertTrue(StorageUsage(category: .caches, size: 4096, count: 0).isEmpty, "a category with bytes but no items is still empty")
        XCTAssertFalse(StorageUsage(category: .caches, size: 0, count: 1).isEmpty)
    }

    func testLocationTitleUsesCategoryTitleOrDirectoryName() {
        let dir = URL(fileURLWithPath: "/var/mobile/Documents/MyFolder", isDirectory: true)
        XCTAssertEqual(StorageLocation.directory(dir).title, "MyFolder")
        XCTAssertEqual(StorageLocation.category(.caches).title, StorageCategory.caches.title)
    }

    func testEntrySortKeysExposeNameDateAndSize() {
        let url = URL(fileURLWithPath: "/tmp/app.ipa")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let entry = StorageEntry(
            id: "app-1", name: "app.ipa", version: "1.0", size: 2048, date: date,
            url: url, isDirectory: false, childCount: 0, isProtected: false, appUuid: nil
        )
        XCTAssertEqual(entry.sortName, "app.ipa")
        XCTAssertEqual(entry.sortDate, date)
        XCTAssertEqual(entry.sortSize, 2048)
    }

    func testAggregateTotalBytesSumsDisjointRoots() throws {
        let fm = FileManager.default
        XCTAssertEqual(StorageAggregateAccounting.totalBytes(in: [], fileManager: fm), 0, "no roots is zero bytes")

        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) } // try? ok: test teardown
        try Data(repeating: 7, count: 100).write(to: root.appendingPathComponent("a.bin"))
        try Data(repeating: 9, count: 50).write(to: root.appendingPathComponent("b.bin"))
        // Allocated size rounds up to filesystem blocks, so assert the real bytes as a floor.
        XCTAssertGreaterThanOrEqual(StorageAggregateAccounting.totalBytes(in: [root], fileManager: fm), 150)
    }
}
