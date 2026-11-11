import Foundation
import XCTest
@testable import VexSign

final class WebDAVTransferPolicyTests: XCTestCase {
    func testOverlappingPathsAndInboxAreRejected() {
        let root = URL(fileURLWithPath: "/tmp/vexsign-inbox", isDirectory: true)
        func url(_ path: String) -> URL { root.appendingPathComponent(path) }
        let rejected: [(URL, URL)] = [
            (url("a"), url("a")),
            (url("a"), url("A")), // Same on a case-insensitive volume.
            (url("folder/file"), url("folder")),
            (url("folder"), url("folder/file")),
            (url("folder/./file"), url("folder/file")),
            (root, url("other")),
            (url("other"), root),
            (url("other"), URL(fileURLWithPath: "/tmp/vexsign-inbox-other/file"))
        ]
        for (source, destination) in rejected {
            XCTAssertFalse(WebDAVTransferPolicy.permits(source: source, destination: destination, inbox: root),
                           "\(source.path) -> \(destination.path)")
        }
        XCTAssertTrue(WebDAVTransferPolicy.permits(source: url("folder"), destination: url("folder-copy"), inbox: root))
        XCTAssertTrue(WebDAVTransferPolicy.permits(source: url("one/file"), destination: url("two/file"), inbox: root))
    }

    func testExistingSymlinkCannotAliasSourceOrEscapeInbox() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createSymbolicLink(at: outside, withDestinationURL: root.deletingLastPathComponent())
        XCTAssertFalse(WebDAVTransferPolicy.permits(source: source, destination: alias, inbox: root))
        XCTAssertFalse(WebDAVTransferPolicy.permits(source: source, destination: alias.appendingPathComponent("new"), inbox: root))
        XCTAssertFalse(WebDAVTransferPolicy.permits(source: source, destination: outside.appendingPathComponent("new"), inbox: root))
    }
}
