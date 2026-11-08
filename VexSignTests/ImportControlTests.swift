import Foundation
import XCTest
@testable import VexSign

final class ImportControlTests: XCTestCase {
    func testCancellationIsTerminalBeforeCommit() {
        let control = ImportControl()
        XCTAssertTrue(control.cancel())
        control.resume()
        XCTAssertFalse(control.pause())
        XCTAssertFalse(control.isControllable)
        XCTAssertThrowsError(try control.checkpoint()) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertThrowsError(try control.beginCommit())
    }

    func testPauseBlocksWorkerUntilResume() {
        let control = ImportControl()
        let entered = DispatchSemaphore(value: 0)
        let passed = DispatchSemaphore(value: 0)
        XCTAssertTrue(control.pause())
        DispatchQueue.global().async {
            entered.signal()
            do { try control.checkpoint(); passed.signal() }
            catch { XCTFail("Unexpected checkpoint failure: \(error)") }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(passed.wait(timeout: .now() + 0.03), .timedOut)
        control.resume()
        XCTAssertEqual(passed.wait(timeout: .now() + 2), .success)
    }

    func testStopWakesPausedWorker() {
        let control = ImportControl()
        let ended = DispatchSemaphore(value: 0)
        XCTAssertTrue(control.pause())
        DispatchQueue.global().async {
            defer { ended.signal() }
            do { try control.checkpoint(); XCTFail("Stopped worker passed checkpoint") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
        XCTAssertTrue(control.cancel())
        XCTAssertEqual(ended.wait(timeout: .now() + 2), .success)
    }

    func testCommitCannotBeReportedAsCancelledAfterward() throws {
        let control = ImportControl()
        try control.beginCommit()
        XCTAssertFalse(control.cancel())
        XCTAssertFalse(control.pause())
        XCTAssertFalse(control.isControllable)
        XCTAssertNoThrow(try control.checkpoint())
    }

    func testPausedImportShowsExtractionRatherThanDownloadProgress() {
        let download = Download(id: "fixture", url: URL(fileURLWithPath: "/fixture.ipa"), onlyArchiving: true)
        download.beginImport()
        download.progress = 1
        download.bytesDownloaded = 100
        download.totalBytes = 100
        download.unpackageProgress = 0.35
        download.isPaused = true
        XCTAssertEqual(download.phase, .paused)
        XCTAssertEqual(download.phaseProgress, 0.35, accuracy: 0.001)
        let summary = DownloadProgressSummary([download])
        XCTAssertEqual(summary.phase, .paused)
        XCTAssertEqual(summary.progress, 0.35, accuracy: 0.001)
        XCTAssertTrue(download.canPause)
        XCTAssertTrue(download.canCancel)
    }

    func testAutoSigningDoesNotExposeImportControls() {
        let download = Download(id: "fixture", url: URL(fileURLWithPath: "/fixture.ipa"))
        download.isSigning = true
        XCTAssertFalse(download.canPause)
        XCTAssertFalse(download.canCancel)
    }
}
