import Foundation
import XCTest
@testable import VexSign

final class WebManagerDeletionTests: XCTestCase {
    func testDeletionAndMissingItem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.ipa")
        try Data([1]).write(to: file)
        XCTAssertEqual(WebManagerDeletion.delete(file), .removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(WebManagerDeletion.delete(file), .missing)
    }

    func testRemovalFailureIsNotReportedAsSuccess() {
        let url = URL(fileURLWithPath: "/example/file")
        let result = WebManagerDeletion.delete(url, exists: { _ in true }, remove: { _ in
            throw NSError(domain: "test", code: 1)
        })
        XCTAssertEqual(result, .failed)
    }

    func testRecordedOutcomeDistinguishesMissingFromFailed() {
        // The app, tweak and certificate delete routes share this mapping: a caller
        // that gets 204 must be able to believe the work was done.
        XCTAssertEqual(WebManagerDeletion.outcome(exists: false, removed: false), .missing,
                       "an unknown id is not a successful deletion")
        XCTAssertEqual(WebManagerDeletion.outcome(exists: true, removed: true), .removed)
        XCTAssertEqual(WebManagerDeletion.outcome(exists: true, removed: false), .failed)
    }

    func testRootComparisonNormalizesDotAndSymlinkAliases() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = root.appendingPathComponent("inbox")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: inbox)
        XCTAssertTrue(WebManagerDeletion.isInboxRoot(inbox.appendingPathComponent("."), inbox: inbox))
        XCTAssertTrue(WebManagerDeletion.isInboxRoot(alias, inbox: inbox))
        XCTAssertFalse(WebManagerDeletion.isInboxRoot(inbox.appendingPathComponent("file"), inbox: inbox))
    }
}
