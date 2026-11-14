import XCTest
import UserNotifications
@testable import VexSign

/// Characterization fixtures from DownloadManager at e0eedee. In particular,
/// merged percentages are an unweighted mean, not a byte-weighted estimate.
final class DownloadNotificationBuilderTests: XCTestCase {
    private func download(_ name: String = "fixture.ipa", progress: Double = 0.5,
                          received: Int64 = 512, total: Int64 = 1024, archive: Bool = false) -> Download {
        let download = Download(id: "fixture-id", url: URL(fileURLWithPath: "/fixture/\(name)"), onlyArchiving: archive)
        download.progress = progress
        download.bytesDownloaded = received
        download.totalBytes = total
        download.isActive = true
        return download
    }
    private func bytes(_ count: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: count)
    }

    func testEmptyActiveListProducesNoProgressRequest() {
        XCTAssertNil(DownloadNotificationBuilder.progress(forActiveDownloads: []))
    }

    func testArchiveOnlyItemsProduceNoNetworkNotification() {
        XCTAssertNil(DownloadNotificationBuilder.progress(forActiveDownloads: [download(archive: true)]))
    }

    func testSingleProgressKeepsFilenameBinaryBytesAndTruncatedPercent() throws {
        let request = try XCTUnwrap(DownloadNotificationBuilder.progress(forActiveDownloads: [download(progress: 0.259)]))
        XCTAssertEqual(request.identifier, "merged_download_progress")
        XCTAssertNil(request.trigger)
        XCTAssertEqual(request.content.title, "fixture.ipa")
        XCTAssertEqual(request.content.subtitle, "Progress: 25%")
        XCTAssertEqual(request.content.body, "\(bytes(512)) / \(bytes(1024))")
        XCTAssertNil(request.content.sound)
        XCTAssertEqual(request.content.interruptionLevel, .passive)
    }

    func testMergedPercentIsUnweightedWhileByteCountsAreSummed() throws {
        let first = download("small.ipa", progress: 0.25, received: 250, total: 1000)
        let second = download("large.ipa", progress: 0.75, received: 7500, total: 10000)
        let request = try XCTUnwrap(DownloadNotificationBuilder.progress(forActiveDownloads: [first, second]))
        XCTAssertEqual(request.content.title, "Downloading 2 files")
        XCTAssertEqual(request.content.subtitle, "Overall Progress: 50%")
        XCTAssertEqual(request.content.body, "\(bytes(7750)) / \(bytes(11000))")
    }

    func testArchiveItemsDoNotChangeNetworkCountOrProgress() throws {
        let request = try XCTUnwrap(DownloadNotificationBuilder.progress(forActiveDownloads: [
            download("network.ipa", progress: 0.3), download("local.ipa", progress: 0.9, archive: true)
        ]))
        XCTAssertEqual(request.content.title, "network.ipa")
        XCTAssertEqual(request.content.subtitle, "Progress: 30%")
        XCTAssertEqual(request.content.body, "\(bytes(512)) / \(bytes(1024))")
    }

    func testActiveZeroByteDownloadKeepsZeroPercentPresentation() throws {
        let request = try XCTUnwrap(DownloadNotificationBuilder.progress(forActiveDownloads: [download(progress: 0, received: 0, total: 0)]))
        XCTAssertEqual(request.content.subtitle, "Progress: 0%")
        XCTAssertEqual(request.content.body, "\(bytes(0)) / \(bytes(0))")
    }

    func testSystemNotificationKeepsCallerIdentifierAndDefaultSound() {
        let request = DownloadNotificationBuilder.system(title: "Title", body: "Body", identifier: "caller-id")
        XCTAssertEqual(request.identifier, "caller-id")
        XCTAssertEqual(request.content.title, "Title")
        XCTAssertEqual(request.content.body, "Body")
        XCTAssertEqual(request.content.subtitle, "")
        XCTAssertNotNil(request.content.sound)
        XCTAssertNil(request.trigger)
    }

    func testCompletionNotificationKeepsStatusFilenameAndTimeSensitiveLevel() {
        let request = DownloadNotificationBuilder.completion(for: download(), status: "Finished")
        XCTAssertEqual(request.identifier, "completion_fixture-id")
        XCTAssertEqual(request.content.title, "Finished")
        XCTAssertEqual(request.content.body, "fixture.ipa")
        XCTAssertEqual(request.content.interruptionLevel, .timeSensitive)
        XCTAssertNotNil(request.content.sound)
        XCTAssertNil(request.trigger)
    }
}
