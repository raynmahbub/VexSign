// Host-only tests of the unmodified production storage owner. Synthetic bytes
// and private temporary roots only; no device, account or native FFI is loaded.
#if canImport(DeviceFoundation)
import Foundation
import Darwin
import XCTest
@testable import DeviceFoundation

final class PairingFileStorageTests: XCTestCase {
    private func withRoot(_ work: (URL) throws -> Void) throws {
        let temporary = try XCTUnwrap(Darwin.realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(temporary) }
        let root = URL(fileURLWithPath: String(cString: temporary), isDirectory: true)
            .appendingPathComponent("vexsign-pairing-test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) } // try? ok: fixture teardown only
        try work(root)
    }

    private func fixture(_ marker: String = "one") throws -> Data {
        var record = PairingRecordTestFixtures.classic()
        record["test_marker"] = marker
        return try PairingRecordTestFixtures.data(record)
    }

    private func expect(_ expected: PairingRecordError, _ work: () throws -> Void,
                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try work(), file: file, line: line) {
            XCTAssertEqual($0 as? PairingRecordError, expected, file: file, line: line)
        }
    }

    func testReadsOnlyBoundedRegularFilesWithoutFollowingLinksOrBlockingOnFIFOs() throws {
        try withRoot { root in
            let file = root.appendingPathComponent("source.plist")
            let data = try fixture()
            try data.write(to: file)
            XCTAssertEqual(try PairingFileStorage.read(from: file), data)
            let link = root.appendingPathComponent("link.plist")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
            expect(.unsafeFile) { _ = try PairingFileStorage.read(from: link) }
            expect(.unsafeFile) { _ = try PairingFileStorage.read(from: root) }
            let fifo = root.appendingPathComponent("fifo")
            XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
            expect(.unsafeFile) { _ = try PairingFileStorage.read(from: fifo) }
            let missing = root.appendingPathComponent("missing.plist")
            expect(.missing) { _ = try PairingFileStorage.read(from: missing) }
            expect(.unsafeFile) { _ = try PairingFileStorage.read(from: URL(string: "https://example.invalid/record")!) }
        }
    }

    func testOversizedInputIsRefusedBeforeParsingOrReplacingAnExistingFile() throws {
        try withRoot { root in
            let destination = root.appendingPathComponent("Private/pairing.plist")
            let original = try fixture()
            let review = try PairingFileStorage.install(original, at: destination, replacing: nil)
            let oversized = Data(repeating: 0, count: PairingRecordDocument.maximumSize + 1)
            expect(.oversized) { _ = try PairingFileStorage.install(oversized, at: destination, replacing: review.sha256) }
            XCTAssertEqual(try PairingFileStorage.read(from: destination), original)
            let input = root.appendingPathComponent("oversized.plist")
            try oversized.write(to: input)
            expect(.oversized) { _ = try PairingFileStorage.read(from: input) }
        }
    }

    func testEmptySlotImportAndReviewedReplacementKeepExactBytesAndPermissions() throws {
        try withRoot { root in
            let destination = root.appendingPathComponent("Private/pairing.plist")
            let first = try fixture()
            let review = try PairingFileStorage.install(first, at: destination, replacing: nil)
            expect(.changedRecord) { _ = try PairingFileStorage.install(first, at: destination, replacing: nil) }
            let second = try fixture("two")
            let installed = try PairingFileStorage.install(second, at: destination, replacing: review.sha256)
            XCTAssertEqual(installed.sha256, PairingRecordDocument.fingerprint(second))
            XCTAssertEqual(try PairingFileStorage.read(from: destination), second)
            XCTAssertEqual(try permissions(destination), 0o600)
            XCTAssertEqual(try permissions(destination.deletingLastPathComponent()), 0o700)
            XCTAssertEqual(try destination.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path), ["pairing.plist"])
        }
    }

    func testInvalidReplacementAndPreCommitFailureNeverDestroyTheOriginal() throws {
        try withRoot { root in
            let destination = root.appendingPathComponent("Private/pairing.plist")
            let original = try fixture()
            let review = try PairingFileStorage.install(original, at: destination, replacing: nil)
            expect(.malformed) { _ = try PairingFileStorage.install(Data(), at: destination, replacing: review.sha256) }
            for code in [CocoaError.Code.fileWriteNoPermission, .fileWriteOutOfSpace] {
                XCTAssertThrowsError(try PairingFileStorage.install(fixture("replacement"), at: destination,
                    replacing: review.sha256, beforeCommit: { throw CocoaError(code) }))
                XCTAssertEqual(try PairingFileStorage.read(from: destination), original)
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path), ["pairing.plist"])
        }
    }

    func testAChangedReviewAtCommitNeverClobbersTheNewRecord() throws {
        try withRoot { root in
            let destination = root.appendingPathComponent("Private/pairing.plist")
            let old = try PairingFileStorage.install(fixture(), at: destination, replacing: nil)
            let concurrent = try fixture("concurrent")
            expect(.changedRecord) {
                _ = try PairingFileStorage.install(fixture("candidate"), at: destination, replacing: old.sha256,
                    beforeCommit: { try concurrent.write(to: destination, options: .atomic) })
            }
            XCTAssertEqual(try PairingFileStorage.read(from: destination), concurrent)
        }
    }

    func testAnEmptySlotThatChangesDuringPreparationIsNotOverwritten() throws {
        try withRoot { root in
            let destination = root.appendingPathComponent("Private/pairing.plist")
            let concurrent = try fixture("concurrent")
            expect(.changedRecord) {
                _ = try PairingFileStorage.install(fixture(), at: destination, replacing: nil,
                    beforeCommit: { try concurrent.write(to: destination) })
            }
            XCTAssertEqual(try PairingFileStorage.read(from: destination), concurrent)
        }
    }

    func testReviewedDeletionAndMalformedRecordRecoveryDoNotNeedDeviceTrust() throws {
        try withRoot { root in
            let destination = root.appendingPathComponent("Private/pairing.plist")
            let review = try PairingFileStorage.install(fixture(), at: destination, replacing: nil)
            expect(.changedRecord) { try PairingFileStorage.remove(at: destination, expectedSHA256: String(repeating: "0", count: 64)) }
            let malformed = Data("not a pairing document".utf8)
            try malformed.write(to: destination)
            expect(.changedRecord) { try PairingFileStorage.remove(at: destination, expectedSHA256: review.sha256) }
            let replacement = try fixture("replacement")
            let next = try PairingFileStorage.install(replacement, at: destination,
                replacing: PairingRecordDocument.fingerprint(malformed))
            try PairingFileStorage.remove(at: destination, expectedSHA256: next.sha256)
            expect(.missing) { _ = try PairingFileStorage.read(from: destination) }
            expect(.changedRecord) { try PairingFileStorage.remove(at: destination, expectedSHA256: next.sha256) }
        }
    }

    func testSymlinkedParentsDestinationsAndHardlinksCannotBeModifiedAsPrivateStorage() throws {
        try withRoot { root in
            let outside = root.appendingPathComponent("unrelated")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
            let link = root.appendingPathComponent("Private")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
            expect(.unsafeFile) { _ = try PairingFileStorage.install(fixture(), at: link.appendingPathComponent("pairing.plist"), replacing: nil) }
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
            let source = root.appendingPathComponent("untouched")
            let bytes = Data("untouched".utf8)
            try bytes.write(to: source)
            let destination = root.appendingPathComponent("pairing.plist")
            try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: source)
            expect(.unsafeFile) { _ = try PairingFileStorage.install(fixture(), at: destination, replacing: nil) }
            try FileManager.default.removeItem(at: destination)
            XCTAssertEqual(Darwin.link(source.path, destination.path), 0)
            expect(.unsafeFile) { _ = try PairingFileStorage.install(fixture(), at: destination, replacing: nil) }
            XCTAssertEqual(try Data(contentsOf: source), bytes)
        }
    }

    func testExportRequiresAValidCurrentReviewAndPreservesExactFormatBytes() throws {
        try withRoot { root in
            let source = root.appendingPathComponent("Private/pairing.plist")
            let original = try fixture()
            let review = try PairingFileStorage.install(original, at: source, replacing: nil)
            let exports = root.appendingPathComponent("exports")
            expect(.changedRecord) { _ = try PairingFileStorage.export(from: source, expectedSHA256: "wrong", root: exports) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: exports.path))
            let file = try PairingFileStorage.export(from: source, expectedSHA256: review.sha256, root: exports)
            XCTAssertEqual(file.lastPathComponent, "VexSign-Pairing.plist")
            XCTAssertNotNil(UUID(uuidString: file.deletingLastPathComponent().lastPathComponent))
            XCTAssertEqual(try Data(contentsOf: file), original)
            XCTAssertEqual(try permissions(file), 0o600)
            XCTAssertEqual(try permissions(file.deletingLastPathComponent()), 0o700)
            XCTAssertEqual(try exports.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
            PairingFileStorage.discardExport(at: file, root: exports)
            PairingFileStorage.discardExport(at: file, root: exports)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
            XCTAssertEqual(try PairingFileStorage.read(from: source), original)
        }
    }

    func testExportDismissalCannotDeleteAnArbitraryDirectoryOrSiblingFile() throws {
        try withRoot { root in
            let owned = root.appendingPathComponent("exports")
            let directory = root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let keep = directory.appendingPathComponent("VexSign-Pairing.plist")
            try Data([1]).write(to: keep)
            PairingFileStorage.discardExport(at: keep, root: owned)
            PairingFileStorage.discardExport(at: directory.appendingPathComponent("other.plist"), root: root)
            XCTAssertTrue(FileManager.default.fileExists(atPath: keep.path))
        }
    }

    func testMigrationIsIdempotentAndPreservesCollidingLegacyBytesPrivately() throws {
        try withRoot { root in
            let legacy = root.appendingPathComponent("legacy.plist")
            let destination = root.appendingPathComponent("Private/pairing.plist")
            let original = try fixture()
            try original.write(to: legacy)
            try requireSuccessfulMigration(legacy: legacy, destination: destination)
            try requireSuccessfulMigration(legacy: legacy, destination: destination)
            XCTAssertEqual(try PairingFileStorage.read(from: destination), original)
            let older = try fixture("older")
            try older.write(to: legacy)
            try requireSuccessfulMigration(legacy: legacy, destination: destination)
            XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
            XCTAssertEqual(try PairingFileStorage.read(from: destination), original)
            let retained = try FileManager.default.contentsOfDirectory(at: destination.deletingLastPathComponent(), includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("legacy-") }
            XCTAssertEqual(retained.count, 1)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(retained.first)), older)
            XCTAssertEqual(try permissions(XCTUnwrap(retained.first)), 0o600)
        }
    }

    func testFailedMigrationPreservesSourceAndRejectsAChangedTarget() throws {
        try withRoot { root in
            let legacy = root.appendingPathComponent("legacy.plist")
            let destination = root.appendingPathComponent("Private/pairing.plist")
            let original = try fixture()
            try original.write(to: legacy)
            XCTAssertThrowsError(try PairingFileStorage.migrate(legacy: legacy, destination: destination,
                beforeMove: { _, _ in throw CocoaError(.fileWriteOutOfSpace) }))
            XCTAssertEqual(try PairingFileStorage.read(from: legacy), original)
            let concurrent = try fixture("concurrent")
            expect(.changedRecord) {
                _ = try PairingFileStorage.migrate(legacy: legacy, destination: destination,
                    beforeMove: { _, target in try concurrent.write(to: target) })
            }
            XCTAssertEqual(try PairingFileStorage.read(from: destination), concurrent)
            XCTAssertEqual(try PairingFileStorage.read(from: legacy), original)
        }
    }

    func testRecoveryDeletesOnlyOwnedTemporaryNamesAndNeverCurrentOrLegacyCredentials() throws {
        try withRoot { root in
            let privateDirectory = root.appendingPathComponent("Private")
            let source = privateDirectory.appendingPathComponent("pairing.plist")
            let original = try fixture()
            let review = try PairingFileStorage.install(original, at: source, replacing: nil)
            let exports = root.appendingPathComponent("exports")
            let exported = try PairingFileStorage.export(from: source, expectedSHA256: review.sha256, root: exports)
            let abandoned = privateDirectory.appendingPathComponent(".pairing-" + UUID().uuidString)
            try Data([1]).write(to: abandoned)
            for name in ["legacy-retained.plist", ".pairing-not-owned"] {
                try Data([2]).write(to: privateDirectory.appendingPathComponent(name))
            }
            try PairingFileStorage.recoverTemporaryFiles(privateDirectory: privateDirectory, exports: exports)
            XCTAssertFalse(FileManager.default.fileExists(atPath: exported.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
            XCTAssertEqual(try PairingFileStorage.read(from: source), original)
            for name in ["legacy-retained.plist", ".pairing-not-owned"] {
                XCTAssertTrue(FileManager.default.fileExists(atPath: privateDirectory.appendingPathComponent(name).path))
            }
            try PairingFileStorage.recoverTemporaryFiles(privateDirectory: privateDirectory, exports: exports)
        }
    }

    func testRecoveryHasABoundedEntryBudget() throws {
        try withRoot { root in
            let exports = root.appendingPathComponent("exports")
            try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: false)
            for _ in 0..<130 {
                try FileManager.default.createDirectory(at: exports.appendingPathComponent(UUID().uuidString), withIntermediateDirectories: false)
            }
            try PairingFileStorage.recoverTemporaryFiles(privateDirectory: root.appendingPathComponent("missing"), exports: exports)
            let remaining = try FileManager.default.contentsOfDirectory(atPath: exports.path)
            XCTAssertGreaterThanOrEqual(remaining.count, 2)
        }
    }

    func testAppOwnedLibraryAncestorCannotRedirectThePrivateSlotIntoDocuments() throws {
        try withRoot { root in
            let documents = root.appendingPathComponent("Documents", isDirectory: true)
            try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Library"),
                                                       withDestinationURL: documents)
            let destination = PairingFileStorage.privateURL(in: root)
            XCTAssertEqual(destination.path, root.appendingPathComponent("Library/Application Support/Private/pairingFile.plist").path)
            expect(.unsafeFile) { _ = try PairingFileStorage.install(try fixture(), at: destination, replacing: nil) }
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: documents.path).isEmpty)
            try FileManager.default.removeItem(at: root.appendingPathComponent("Library"))
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Library"),
                withDestinationURL: documents.appendingPathComponent("missing", isDirectory: true))
            expect(.unsafeFile) { _ = try PairingFileStorage.install(try fixture(), at: destination, replacing: nil) }
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: documents.path).isEmpty)
        }
    }

    func testPathLookupHasNoMigrationOrDirectoryCreationSideEffects() {
        let first = PairingFileStorage.path()
        XCTAssertEqual(PairingFileStorage.path(), first)
        XCTAssertTrue(first.hasSuffix("/Private/pairingFile.plist"))
        // No prepare()/migrate() is called here: host tests never touch the app's
        // real Documents or Application Support records.
    }

    /// Keep an unexpected host filesystem failure diagnosable without exporting
    /// raw paths or credential bytes. This does not relax the production checks.
    private func requireSuccessfulMigration(legacy: URL, destination: URL,
                                            file: StaticString = #filePath, line: UInt = #line) throws {
        var checkpoint: stat?
        var selectedTarget: URL?
        do {
            try PairingFileStorage.migrate(legacy: legacy, destination: destination, beforeMove: { source, target in
                var info = stat()
                if lstat(source.path, &info) == 0 { checkpoint = info }
                selectedTarget = target
            })
        } catch {
            var current = stat()
            let sourceExists = lstat(legacy.path, &current) == 0
            let sameIdentity = checkpoint.map { sourceExists && $0.st_dev == current.st_dev && $0.st_ino == current.st_ino }
            let sameSize = checkpoint.map { sourceExists && $0.st_size == current.st_size }
            let sameMTime = checkpoint.map { sourceExists && $0.st_mtimespec.tv_sec == current.st_mtimespec.tv_sec
                && $0.st_mtimespec.tv_nsec == current.st_mtimespec.tv_nsec }
            let sameCTime = checkpoint.map { sourceExists && $0.st_ctimespec.tv_sec == current.st_ctimespec.tv_sec
                && $0.st_ctimespec.tv_nsec == current.st_ctimespec.tv_nsec }
            let targetExists = selectedTarget.map { FileManager.default.fileExists(atPath: $0.path) }
            XCTFail("Migration failed: \(error); source=\(sourceExists), identity=\(String(describing: sameIdentity)), size=\(String(describing: sameSize)), mtime=\(String(describing: sameMTime)), ctime=\(String(describing: sameCTime)), target=\(String(describing: targetExists))", file: file, line: line)
            throw error
        }
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
    }
}
#endif
