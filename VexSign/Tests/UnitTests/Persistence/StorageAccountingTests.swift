import Foundation
import XCTest
@testable import VexSign

final class StorageAccountingTests: XCTestCase {
    func testSandboxAggregateDoesNotFollowSymlinks() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let documents = root.appendingPathComponent("Documents", isDirectory: true)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let temporary = root.appendingPathComponent("tmp", isDirectory: true)
        let external = root.appendingPathComponent("external", isDirectory: true)
        try [documents, library, temporary, external].forEach {
            try fileManager.createDirectory(at: $0, withIntermediateDirectories: true)
        }
        defer { try? fileManager.removeItem(at: root) }

        try Data(repeating: 0x41, count: 32 * 1024).write(to: documents.appendingPathComponent("owned.bin"))
        try Data(repeating: 0x42, count: 16 * 1024).write(to: library.appendingPathComponent("owned.bin"))
        let outsideFile = external.appendingPathComponent("large.bin")
        try Data(repeating: 0x43, count: 2 * 1024 * 1024).write(to: outsideFile)
        let alias = temporary.appendingPathComponent("external-alias")
        try fileManager.createSymbolicLink(at: alias, withDestinationURL: outsideFile)

        XCTAssertEqual(CleanupRemovalPolicy.allocatedSizeWithoutFollowingSymlinks(at: alias), 0)
        let expected = [documents, library, temporary].reduce(Int64(0)) {
            $0 + CleanupRemovalPolicy.allocatedSizeWithoutFollowingSymlinks(at: $1)
        }
        XCTAssertGreaterThan(expected, 0)
        XCTAssertEqual(StorageAggregateAccounting.totalBytes(in: [documents, library, temporary]), expected)
    }

    func testPurgeEstimateAndCommittedRemovalUseTheSameProtectedRootRules() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let protectedDirectory = root.appendingPathComponent("state", isDirectory: true)
        try fileManager.createDirectory(at: protectedDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let removable = root.appendingPathComponent("discard.bin")
        try Data(repeating: 0x51, count: 24 * 1024).write(to: removable)
        let protectedFile = protectedDirectory.appendingPathComponent("store.sqlite")
        try Data(repeating: 0x52, count: 48 * 1024).write(to: protectedFile)
        let protectedRoots = [protectedFile]

        let estimate = StorageScanner.purgeableSize(in: root, protectedRoots: protectedRoots)
        let freed = StorageScanner.purge(contentsOf: root, protectedRoots: protectedRoots)

        XCTAssertGreaterThan(estimate, 0)
        XCTAssertEqual(freed, estimate, "The estimate must count exactly the items the purge can remove")
        XCTAssertFalse(fileManager.fileExists(atPath: removable.path))
        XCTAssertTrue(fileManager.fileExists(atPath: protectedFile.path), "A protected descendant retains its parent directory")
    }
}
