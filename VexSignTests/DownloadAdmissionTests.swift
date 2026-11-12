import Foundation
import XCTest
@testable import VexSign

/// No real network, notification registration, background sessions or Live Activities.
final class DownloadAdmissionTests: XCTestCase {
    @MainActor
    private func withManager(_ body: (DownloadManager) throws -> Void) rethrows {
        let keys = [DownloadPreferences.maxParallelKey, DownloadPreferences.wifiOnlyKey,
                    DownloadPreferences.chargeOnlyKey, GameMode.enabledKey]
        let defaults = UserDefaults.standard
        let previous = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(1, forKey: DownloadPreferences.maxParallelKey)
        defaults.set(false, forKey: DownloadPreferences.wifiOnlyKey)
        defaults.set(false, forKey: DownloadPreferences.chargeOnlyKey)
        defaults.set(false, forKey: GameMode.enabledKey)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HeldDownloadProtocol.self]
        let session = URLSession(configuration: configuration)
        let manager = DownloadManager(configureServices: false)
        manager._foregroundSession = session
        manager._backgroundSession = session
        defer {
            for download in manager.downloads { download.task?.cancel() }
            session.invalidateAndCancel()
        }
        try body(manager)
    }

    @MainActor
    func testVerificationClaimsOwnershipBeforeReturningAndCancelInvalidatesIt() throws {
        let manager = DownloadManager(configureServices: false)
        let download = Download(id: "verification-test", url: url(99))
        manager.downloads.append(download)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ipa")
        try Data("payload".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        // Pause before starting, making the worker wait at its first cooperative checkpoint.
        XCTAssertTrue(download.importControl.pause())
        download.isPaused = true
        try manager.handlePackageFile(url: file, dl: download)
        XCTAssertTrue(download.isVerifying)
        XCTAssertEqual(download.phase, .paused)
        XCTAssertEqual(download.phaseProgress, 0)
        XCTAssertNil(download.packageVerification.begin())
        try manager.handlePackageFile(url: file, dl: download)
        manager.cancelDownload(download)
        XCTAssertFalse(download.importControl.isControllable)
        XCTAssertFalse(download.packageVerification.acceptOverride())
        // Cancellation is cooperative: the row stays until the worker releases the file.
        XCTAssertTrue(download.isVerifying)
    }

    @MainActor
    func testPolicyTransitionHoldsRunningTaskWithoutUndoingManualPause() {
        withManager { manager in
            let running = manager.startDownload(from: url(90))
            let manual = manager.startDownload(from: url(91))
            waitForTaskState(running.task, equals: .running)
            manager.pauseDownload(manual)
            manager.reconcileNetworkPolicy(allowed: false)
            waitForTaskState(running.task, equals: .suspended)
            XCTAssertEqual(running.task?.state, .suspended)
            XCTAssertTrue(running.isWaitingForSlot)
            XCTAssertFalse(running.isPaused)
            manager.reconcileNetworkPolicy(allowed: true)
            waitForTaskState(running.task, equals: .running)
            XCTAssertEqual(running.task?.state, .running)
            XCTAssertTrue(manual.isPaused)
            XCTAssertEqual(manual.task?.state, .suspended)
        }
    }

    /// Characterization for the split of `DownloadManager.swift`.
    ///
    /// The transfer-control members now live in `DownloadManager+TransferControl.swift`.
    /// A split is only safe if the behaviour is unchanged, and the tests above already
    /// exercise `reconcileNetworkPolicy`, `pauseDownload` and `drainNetworkQueue` through
    /// the real type — so they cover the moved bodies without knowing where they live.
    /// What they cannot see is a member quietly going missing, so that is what is pinned.
    @MainActor
    func testTransferControlMembersAreStillReachable() {
        let manager = DownloadManager(configureServices: false)
        let download = Download(id: "split-check", url: url(1))
        manager.downloads.append(download)

        // Every member the split moved, called once so a missing one fails to compile.
        XCTAssertEqual(manager.getDownload(by: "split-check")?.id, "split-check")
        XCTAssertEqual(manager.getDownloadIndex(by: "split-check"), 0)
        XCTAssertNil(manager.getDownload(by: "absent"))
        // `isManualDownload` is a substring test, not a lookup: a manual download is
        // identified by its id carrying this marker.
        XCTAssertFalse(manager.isManualDownload("split-check"))
        XCTAssertTrue(manager.isManualDownload("VexSignManualDownload-1"))
        XCTAssertEqual(manager.nonManualDownloads.count, manager.downloads.count)
        manager.reconcileNetworkPolicy(allowed: false)
        manager.drainNetworkQueue()
        manager.pauseDownload(download)
        manager.cancelDownload(download)
        manager.cancelAllDownloads()
    }

    /// URLSession publishes suspend/resume state asynchronously. Wait for that observation
    /// instead of treating a still-pending transition as a policy failure.
    @MainActor
    private func waitForTaskState(
        _ task: URLSessionTask?,
        equals expected: URLSessionTask.State,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let settled = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in task?.state == expected },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed, file: file, line: line)
    }

    private func url(_ index: Int) -> URL { URL(string: "https://example.invalid/\(index).ipa")! }

    @MainActor
    func testCapQueuesExcessWorkAndDuplicateDoesNotReplaceRunningTask() throws {
        try withManager { manager in
            let first = manager.startDownload(from: url(1))
            let task = try XCTUnwrap(first.task)
            let second = manager.startDownload(from: url(2))
            XCTAssertEqual(manager.activeNetworkDownloads.count, 1)
            XCTAssertEqual(first.task?.state, .running)
            XCTAssertEqual(second.task?.state, .suspended)
            XCTAssertEqual(second.phase, .queued)
            XCTAssertTrue(second.isWaitingForSlot)
            XCTAssertTrue(manager.startDownload(from: url(1)) === first)
            XCTAssertTrue(first.task === task)
            XCTAssertEqual(manager.downloads.count, 2)
        }
    }

    @MainActor
    func testSlotReleaseAdmitsNextWaitingTransfer() throws {
        try withManager { manager in
            let first = manager.startDownload(from: url(1))
            let second = manager.startDownload(from: url(2))
            let third = manager.startDownload(from: url(3))
            let task = try XCTUnwrap(first.task)
            first.progress = 1
            manager.networkTransferFinished(first, task: task)
            XCTAssertTrue(second.isActive)
            XCTAssertFalse(second.isWaitingForSlot)
            XCTAssertTrue(third.isWaitingForSlot)
            XCTAssertEqual(manager.activeNetworkDownloads.count, 1)
        }
    }

    @MainActor
    func testPauseAllIncludesQueuedTransfersAndResumePreservesTaskOwnership() throws {
        try withManager { manager in
            let first = manager.startDownload(from: url(1))
            let second = manager.startDownload(from: url(2))
            let original = try XCTUnwrap(first.task)
            manager.pauseAllDownloads()
            XCTAssertTrue(first.isPaused)
            XCTAssertTrue(second.isPaused)
            XCTAssertEqual(manager.activeNetworkDownloads.count, 0)
            manager.drainNetworkQueue()
            XCTAssertEqual(manager.activeNetworkDownloads.count, 0)
            manager.resumeAllDownloads()
            XCTAssertTrue(first.task === original)
            XCTAssertEqual(manager.activeNetworkDownloads.count, 1)
            XCTAssertTrue(second.isWaitingForSlot)
        }
    }

    @MainActor
    func testResumeAndQueueDrainRespectGameMode() {
        withManager { manager in
            let first = manager.startDownload(from: url(1))
            let second = manager.startDownload(from: url(2))
            manager.pauseDownload(first)
            manager.pauseAllDownloads()
            UserDefaults.standard.set(true, forKey: GameMode.enabledKey)
            manager.resumeDownload(first)
            manager.drainNetworkQueue()
            XCTAssertEqual(manager.activeNetworkDownloads.count, 0)
            XCTAssertTrue(first.isPaused)
            XCTAssertTrue(second.isPaused)
        }
    }

    @MainActor
    func testStagingNamesCannotCollideOrEscapeTheirOwnerDirectory() {
        let root = URL(fileURLWithPath: "/fixture/staging", isDirectory: true)
        let first = DownloadStagingName.destination(in: root, suggestedFilename: "App.ipa")
        let second = DownloadStagingName.destination(in: root, suggestedFilename: "App.ipa")
        XCTAssertNotEqual(first, second)
        for name in ["../../App.ipa", "../..", "a\\b.ipa", "", String(repeating: "🚀", count: 300) + ".ipa"] {
            let url = DownloadStagingName.destination(in: root, suggestedFilename: name)
            XCTAssertEqual(url.deletingLastPathComponent(), root)
            XCTAssertLessThanOrEqual(url.lastPathComponent.decomposedStringWithCanonicalMapping.utf8.count, 255)
            XCTAssertFalse(url.lastPathComponent.contains("\\"))
        }
    }

    @MainActor
    func testOldCompletionCannotReleaseReplacementTaskSlot() throws {
        try withManager { manager in
            let first = manager.startDownload(from: url(1))
            let oldTask = try XCTUnwrap(first.task)
            let replacement = manager._foregroundSession.downloadTask(with: url(1))
            first.task = replacement
            first.isActive = true
            manager.networkTransferFinished(first, task: oldTask)
            XCTAssertTrue(first.isActive)
            oldTask.cancel()
        }
    }
}

private final class HeldDownloadProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {} // Deliberately held until the test cancels the session.
    override func stopLoading() {}
}
