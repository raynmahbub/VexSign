import Foundation
import XCTest
@testable import VexSign

final class InstallationArchiveTests: XCTestCase {
    private func fixture(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    func testUniqueWorkspacesDoNotOwnLibraryOrExportFiles() throws {
        try fixture { root in
            let original = root.appendingPathComponent("Original.app")
            let exported = root.appendingPathComponent("Export.ipa")
            try Data([1]).write(to: original)
            try Data([2]).write(to: exported)
            var first: InstallationArchive? = try InstallationArchive(temporaryRoot: root)
            var second: InstallationArchive? = try InstallationArchive(temporaryRoot: root)
            let firstURL = try XCTUnwrap(first?.directory)
            let secondURL = try XCTUnwrap(second?.directory)
            XCTAssertNotEqual(firstURL, secondURL)
            first = nil
            XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: secondURL.path))
            second = nil
            XCTAssertFalse(FileManager.default.fileExists(atPath: secondURL.path))
            XCTAssertEqual(try Data(contentsOf: original), Data([1]))
            XCTAssertEqual(try Data(contentsOf: exported), Data([2]))
        }
    }

    private func retainedCompletion(for lease: InstallationArchive) -> () -> Void {
        { withExtendedLifetime(lease) {} }
    }

    func testStreamCompletionRetainsWorkspaceAfterInstallerReleasesIt() throws {
        try fixture { root in
            var owner: InstallationArchive? = try InstallationArchive(temporaryRoot: root)
            let directory = try XCTUnwrap(owner?.directory)
            let package = directory.appendingPathComponent("Archive.ipa")
            try Data([1, 2, 3]).write(to: package)
            var completion: (() -> Void)? = retainedCompletion(for: try XCTUnwrap(owner))
            owner = nil
            XCTAssertEqual(try Data(contentsOf: package), Data([1, 2, 3]))
            completion?()
            XCTAssertTrue(FileManager.default.fileExists(atPath: package.path))
            completion = nil
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        }
    }

    func testArchiveBlocksCleanupUntilTheLastStreamReleasesIt() throws {
        try fixture { root in
            let registry = AppOperationRegistry()
            var archive: InstallationArchive? = try InstallationArchive(temporaryRoot: root, registry: registry)
            let directory = try XCTUnwrap(archive?.directory)
            var stream: (() -> Void)? = retainedCompletion(for: try XCTUnwrap(archive))
            archive = nil
            XCTAssertNil(registry.acquireCleanup(), "A stopped installer must not expose its still-served IPA to cleanup")
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
            XCTAssertNotNil(stream)
            stream = nil
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
            XCTAssertNotNil(registry.acquireCleanup())
        }
    }

    func testArchiveDoesNotStartWhileCleanupOwnsTheBoundary() throws {
        try fixture { root in
            let registry = AppOperationRegistry()
            let cleanup = try XCTUnwrap(registry.acquireCleanup())
            XCTAssertThrowsError(try InstallationArchive(temporaryRoot: root, registry: registry))
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
            withExtendedLifetime(cleanup) {}
        }
    }

    func testFailedWorkerCleansPartialArchive() throws {
        enum Failure: Error { case cancelled }
        try fixture { root in
            var directory: URL?
            func worker() throws {
                let lease = try InstallationArchive(temporaryRoot: root)
                directory = lease.directory
                defer { withExtendedLifetime(lease) {} }
                try Data([1]).write(to: lease.directory.appendingPathComponent("Partial.zip"))
                throw Failure.cancelled
            }
            XCTAssertThrowsError(try worker())
            XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(directory).path))
        }
    }

    func testLookaheadIsOnlyForOTAToOTAEntries() {
        XCTAssertTrue(InstallPreparationPolicy.allows(installationMethod: 0, currentIsExport: false, nextIsExport: false))
        for method in [-1, 1, 2, 3] {
            XCTAssertFalse(InstallPreparationPolicy.allows(installationMethod: method, currentIsExport: false, nextIsExport: false))
        }
        for (currentExport, nextExport) in [(true, false), (false, true), (true, true)] {
            XCTAssertFalse(InstallPreparationPolicy.allows(installationMethod: 0,
                currentIsExport: currentExport, nextIsExport: nextExport))
        }
    }
}
