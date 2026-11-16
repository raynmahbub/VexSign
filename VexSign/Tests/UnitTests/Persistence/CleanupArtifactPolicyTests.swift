import Foundation
import XCTest
@testable import VexSign

final class CleanupArtifactPolicyTests: XCTestCase {
    func testDownloadedArtifactMustBeARegularFileStrictlyInsideOwnedStaging() throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let staging = temporaryRoot.appendingPathComponent("VexSignDownloads", isDirectory: true)
        let documents = temporaryRoot.appendingPathComponent("Documents", isDirectory: true)
        let signed = documents.appendingPathComponent("Signed", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: signed, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let downloaded = staging.appendingPathComponent("download.ipa")
        let libraryArtifact = signed.appendingPathComponent("committed.ipa")
        try Data("download".utf8).write(to: downloaded)
        try Data("committed".utf8).write(to: libraryArtifact)

        func eligible(_ url: URL) -> Bool {
            CleanupArtifactPolicy.isSafeDownloadedArtifact(
                url, stagingRoot: staging, temporaryRoot: temporaryRoot,
                protectedRoots: [documents], fileManager: fileManager
            )
        }

        XCTAssertTrue(eligible(downloaded))
        XCTAssertFalse(eligible(staging), "The staging root itself is not a deletable artifact")
        XCTAssertFalse(eligible(libraryArtifact), "A committed library artifact is outside download staging")

        let sibling = temporaryRoot.appendingPathComponent("VexSignDownloads-old", isDirectory: true)
        try fileManager.createDirectory(at: sibling, withIntermediateDirectories: true)
        let lookalike = sibling.appendingPathComponent("keep.ipa")
        try Data("keep".utf8).write(to: lookalike)
        XCTAssertFalse(eligible(lookalike), "A sibling sharing the root's string prefix is not contained")
    }

    func testDownloadedArtifactContainmentResolvesSymlinkEscapesAndRejectsSymlinkFiles() throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let staging = temporaryRoot.appendingPathComponent("VexSignDownloads", isDirectory: true)
        let documents = temporaryRoot.appendingPathComponent("Documents", isDirectory: true)
        let signed = documents.appendingPathComponent("Signed", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: signed, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let protectedFile = signed.appendingPathComponent("keep.ipa")
        try Data("library".utf8).write(to: protectedFile)
        let fileLink = staging.appendingPathComponent("file-link.ipa")
        try fileManager.createSymbolicLink(at: fileLink, withDestinationURL: protectedFile)

        let directoryLink = staging.appendingPathComponent("directory-link", isDirectory: true)
        try fileManager.createSymbolicLink(at: directoryLink, withDestinationURL: signed)
        let escapedThroughParent = directoryLink.appendingPathComponent("keep.ipa")

        func eligible(_ url: URL) -> Bool {
            CleanupArtifactPolicy.isSafeDownloadedArtifact(
                url, stagingRoot: staging, temporaryRoot: temporaryRoot,
                protectedRoots: [documents], fileManager: fileManager
            )
        }

        XCTAssertFalse(eligible(fileLink), "Removing a staged symlink could target a committed artifact")
        XCTAssertFalse(eligible(escapedThroughParent), "Resolved parent symlinks must remain inside staging")
    }
}

final class CleanupRemovalPolicyTests: XCTestCase {
    func testRemovalRequiresComponentAwareContainmentAndSucceedsBeforeBytesAreCounted() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let target = root.appendingPathComponent("owned.txt")
        try Data("owned bytes".utf8).write(to: target)
        let expectedSize = fileManager.allocatedSize(at: target)
        let removedSize = try XCTUnwrap(CleanupRemovalPolicy.remove(target, beneath: root))
        XCTAssertEqual(removedSize, expectedSize)
        XCTAssertFalse(fileManager.fileExists(atPath: target.path))
        XCTAssertNil(try CleanupRemovalPolicy.remove(target, beneath: root), "Removing an absent item is idempotent, not a second deletion")

        let siblingRoot = root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-sibling", isDirectory: true)
        try fileManager.createDirectory(at: siblingRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: siblingRoot) }
        let siblingFile = siblingRoot.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: siblingFile)
        XCTAssertThrowsError(try CleanupRemovalPolicy.remove(siblingFile, beneath: root))
        XCTAssertTrue(fileManager.fileExists(atPath: siblingFile.path))
    }

    func testRemovalRejectsSymlinkEscapesAndProtectedIntersections() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let external = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: external, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
            try? fileManager.removeItem(at: external)
        }

        let protected = root.appendingPathComponent("protected", isDirectory: true)
        try fileManager.createDirectory(at: protected, withIntermediateDirectories: true)
        let protectedFile = protected.appendingPathComponent("database.sqlite")
        try Data("database".utf8).write(to: protectedFile)
        XCTAssertThrowsError(try CleanupRemovalPolicy.remove(protected, beneath: root, protectedRoots: [protectedFile]))
        XCTAssertTrue(fileManager.fileExists(atPath: protectedFile.path))

        let internalTarget = root.appendingPathComponent("owned", isDirectory: true)
        try fileManager.createDirectory(at: internalTarget, withIntermediateDirectories: true)
        let internalFile = internalTarget.appendingPathComponent("keep.txt")
        try Data("still owned".utf8).write(to: internalFile)
        let internalAlias = root.appendingPathComponent("alias", isDirectory: true)
        try fileManager.createSymbolicLink(at: internalAlias, withDestinationURL: internalTarget)
        XCTAssertThrowsError(try CleanupRemovalPolicy.remove(internalAlias.appendingPathComponent("keep.txt"), beneath: root))
        XCTAssertTrue(fileManager.fileExists(atPath: internalFile.path))

        let externalFile = external.appendingPathComponent("keep.txt")
        try Data("outside".utf8).write(to: externalFile)
        let link = root.appendingPathComponent("escape")
        try fileManager.createSymbolicLink(at: link, withDestinationURL: externalFile)
        XCTAssertThrowsError(try CleanupRemovalPolicy.remove(link, beneath: root))
        XCTAssertTrue(fileManager.fileExists(atPath: externalFile.path))
    }
}
