import Foundation
import UIKit
import XCTest
@testable import VexSign

final class TaskIconArchiveTests: XCTestCase {
    @MainActor
    private func fixture(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    @MainActor
    private func icon() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
    }

    @MainActor
    func testOfflineThumbnailSurvivesNewArchiveInstance() throws {
        try fixture { root in
            try TaskIconArchive(root: root).store(icon(), for: "record")
            let restored = TaskIconArchive(root: root).image(for: "record")
            XCTAssertEqual(restored?.size.width, 64)
            XCTAssertEqual(restored?.size.height, 64)
        }
    }

    @MainActor
    func testPruneKeepsOnlyRetainedRecordsAndClearRemovesIcons() throws {
        try fixture { root in
            let archive = TaskIconArchive(root: root)
            try archive.store(icon(), for: "keep")
            try archive.store(icon(), for: "remove")
            try archive.prune(keeping: ["keep"])
            XCTAssertNotNil(archive.image(for: "keep"))
            XCTAssertNil(archive.image(for: "remove"))
            try archive.prune(keeping: [])
            XCTAssertNil(archive.image(for: "keep"))
        }
    }

    @MainActor
    func testUntrustedRecordIDCannotBecomeAPath() throws {
        try fixture { root in
            let archive = TaskIconArchive(root: root)
            try archive.store(icon(), for: "../../outside")
            let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            XCTAssertEqual(files.count, 1)
            XCTAssertEqual(files.first?.deletingLastPathComponent().path, root.path)
            XCTAssertEqual(files.first?.lastPathComponent.count, 68)
            XCTAssertNotNil(archive.image(for: "../../outside"))
        }
    }

    @MainActor
    func testMissingIconGracefullyFallsBack() throws {
        try fixture { root in
            XCTAssertNil(TaskIconArchive(root: root).image(for: "missing"))
            XCTAssertNoThrow(try TaskIconArchive(root: root).prune(keeping: []))
        }
    }
}
