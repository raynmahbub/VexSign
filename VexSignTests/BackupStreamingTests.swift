import Foundation
import CryptoKit
import XCTest
@testable import VexSign

final class BackupStreamingTests: XCTestCase {
    private let password = "streaming backup test password"

    func testRestoreTallyCountsOnlySuccessfulCallbacksAsAdded() {
        var tally = BackupRestoreTally()
        tally.recordAttempt(error: nil)
        tally.recordAttempt(error: NSError(domain: "restore", code: 1))
        tally.recordSkipped()

        XCTAssertEqual(tally.added, 1)
        XCTAssertEqual(tally.skipped, 2)
    }
    private let headerCount = 7 + 1 + 16 + 60

    private func fixture(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func writeBackup(_ payload: Data, root: URL) throws -> URL {
        let source = root.appendingPathComponent("source.zip")
        let backup = root.appendingPathComponent("backup.vexbackup")
        try payload.write(to: source)
        try BackupCrypto.sealFile(source, to: backup, password: password)
        return backup
    }

    private func assertRejected(_ bytes: Data, root: URL, password: String? = nil,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        let damaged = root.appendingPathComponent("damaged.vexbackup")
        let output = root.appendingPathComponent("rejected.zip")
        try bytes.write(to: damaged)
        XCTAssertThrowsError(try BackupCrypto.unsealFile(damaged, to: output, password: password ?? self.password), file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), file: file, line: line)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertFalse(leftovers.contains { $0.hasPrefix(".vexbackup-") }, file: file, line: line)
    }

    func testMultiChunkRoundTripAndIncrementalDigest() throws {
        try fixture { root in
            let payload = Data(repeating: 0xA5, count: BackupCrypto.streamChunkBytes * 2 + 17)
            let backup = try writeBackup(payload, root: root)
            XCTAssertTrue(BackupCrypto.isEncrypted(backup))
            XCTAssertTrue(BackupCrypto.needsPassword(backup))
            let output = root.appendingPathComponent("restored.zip")
            let hash = try BackupCrypto.unsealFile(backup, to: output, password: password)
            XCTAssertEqual(try Data(contentsOf: output), payload)
            XCTAssertEqual(hash, SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined())
        }
    }

    func testEmptyStreamStillRequiresAnAuthenticatedTerminalRecord() throws {
        try fixture { root in
            let backup = try writeBackup(Data(), root: root)
            let bytes = try Data(contentsOf: backup)
            XCTAssertEqual(bytes.count, headerCount + 4 + 16)
            let output = root.appendingPathComponent("empty.zip")
            _ = try BackupCrypto.unsealFile(backup, to: output, password: password)
            XCTAssertEqual(try Data(contentsOf: output), Data())
            try assertRejected(Data(bytes.dropLast()), root: root)
        }
    }

    func testWrongAndMissingPasswordDoNotPublishPlaintext() throws {
        try fixture { root in
            let backup = try writeBackup(Data([1, 2, 3]), root: root)
            let bytes = try Data(contentsOf: backup)
            try assertRejected(bytes, root: root, password: "wrong")
            try assertRejected(bytes, root: root, password: "")
        }
    }

    func testCiphertextEnvelopeAndLengthTamperingFailClosed() throws {
        try fixture { root in
            let backup = try writeBackup(Data(repeating: 1, count: 32), root: root)
            let original = try Data(contentsOf: backup)
            for offset in [8, 30, headerCount, headerCount + 4, original.count - 1] {
                var modified = original
                modified[offset] ^= 0xFF
                try assertRejected(modified, root: root)
            }
        }
    }

    func testTruncationAtARecordBoundaryAndTrailingBytesAreRejected() throws {
        try fixture { root in
            let backup = try writeBackup(Data(repeating: 1, count: 32), root: root)
            let bytes = try Data(contentsOf: backup)
            try assertRejected(Data(bytes.dropLast(20)), root: root)
            try assertRejected(bytes + Data([0]), root: root)
        }
    }

    func testReorderedAndDuplicatedRecordsAreRejected() throws {
        try fixture { root in
            let payload = Data(repeating: 1, count: BackupCrypto.streamChunkBytes)
                + Data(repeating: 2, count: BackupCrypto.streamChunkBytes)
            let backup = try writeBackup(payload, root: root)
            let bytes = try Data(contentsOf: backup)
            let recordBytes = 4 + BackupCrypto.streamChunkBytes + 16
            let first = bytes.subdata(in: headerCount..<(headerCount + recordBytes))
            let second = bytes.subdata(in: (headerCount + recordBytes)..<(headerCount + recordBytes * 2))
            let header = Data(bytes.prefix(headerCount))
            let terminal = Data(bytes.suffix(20))
            try assertRejected(header + second + first + terminal, root: root)
            try assertRejected(header + first + first + terminal, root: root)
        }
    }

    func testExistingDestinationIsNeverOverwritten() throws {
        try fixture { root in
            let backup = try writeBackup(Data([1]), root: root)
            let existing = root.appendingPathComponent("existing.zip")
            try Data([42]).write(to: existing)
            XCTAssertThrowsError(try BackupCrypto.unsealFile(backup, to: existing, password: password))
            XCTAssertEqual(try Data(contentsOf: existing), Data([42]))
            XCTAssertThrowsError(try BackupCrypto.sealFile(existing, to: backup, password: password))
            let output = root.appendingPathComponent("check.zip")
            _ = try BackupCrypto.unsealFile(backup, to: output, password: password)
            XCTAssertEqual(try Data(contentsOf: output), Data([1]))
        }
    }

    func testLegacyEnvelopeAndPlaintextContainersRemainReadable() throws {
        try fixture { root in
            let payload = Data([1, 2, 3])
            let encrypted = try BackupCrypto.seal(payload, password: password)
            for (index, bytes) in [encrypted, Data("VEXBK0\n".utf8) + payload].enumerated() {
                let input = root.appendingPathComponent("legacy\(index).vexbackup")
                let output = root.appendingPathComponent("legacy\(index).zip")
                try bytes.write(to: input)
                _ = try BackupCrypto.unsealFile(input, to: output, password: password)
                XCTAssertEqual(try Data(contentsOf: output), payload)
            }
        }
    }

    func testIndependentAESGCMReferenceFixture() throws {
        // Generated independently with Python cryptography AESGCM/PBKDF2, not
        // with the Swift writer. Two short records and a mandatory terminal tag.
        let fixtureBase64 = "VkVYQkszCgEAAQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobtwqij4/pjloT74YBg3Tu6jO3tPX5Uda2vDGO+ZkTllSHNgq1FsVc9xLOPuDH3gvhAAAADVjZzY3cS+2de9zbUHkxCPUohgfylJB58MOQ/zPaAAAADXi/0ZtkkllmelsjXOaNaOYI7CwV1dPbY32PdXLVAAAAADqjLUak+LX/0YKURTVB2I0="
        try fixture { root in
            let input = root.appendingPathComponent("reference.vexbackup")
            let output = root.appendingPathComponent("reference.zip")
            try XCTUnwrap(Data(base64Encoded: fixtureBase64)).write(to: input)
            let hash = try BackupCrypto.unsealFile(input, to: output, password: password)
            XCTAssertEqual(try Data(contentsOf: output), Data("VexSign streaming fixture\n".utf8))
            XCTAssertEqual(hash, "d043b68d17b8a9f959a8d02b4ef27b25fdec5e3dd91065b70412d32ee9db9a16")
        }
    }

    func testOversizedLegacyFileIsRejectedBeforeBufferAllocation() throws {
        try fixture { root in
            let input = root.appendingPathComponent("oversized.vexbackup")
            let output = root.appendingPathComponent("oversized.zip")
            try Data("VEXBK2\n".utf8).write(to: input)
            let handle = try FileHandle(forWritingTo: input)
            defer { try? handle.close() }
            // A sparse file exercises the size guard without allocating 256 MiB.
            try handle.truncate(atOffset: 256 * 1024 * 1024 + 1)
            XCTAssertThrowsError(try BackupCrypto.unsealFile(input, to: output, password: password)) { error in
                XCTAssertEqual(error as? BackupCrypto.Failure, .legacyTooLarge)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
    }

    func testPasswordlessStreamUsesDeviceEnvelope() throws {
        let account = "streaming.test.probe.\(UUID().uuidString)"
        do {
            try SecureSecretStore.write(Data([1]), account: account)
            try SecureSecretStore.delete(account)
        } catch { throw XCTSkip("This host has no usable Keychain: \(error.localizedDescription)") }
        try fixture { root in
            let input = root.appendingPathComponent("device.zip")
            let backup = root.appendingPathComponent("device.vexbackup")
            let output = root.appendingPathComponent("device-restored.zip")
            try Data([1, 2]).write(to: input)
            try BackupCrypto.sealFile(input, to: backup, password: "")
            XCTAssertTrue(BackupCrypto.isEncrypted(backup))
            XCTAssertFalse(BackupCrypto.needsPassword(backup))
            _ = try BackupCrypto.unsealFile(backup, to: output, password: "")
            XCTAssertEqual(try Data(contentsOf: output), Data([1, 2]))
        }
    }

    func testCancellationDoesNotPublishEitherDestination() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let backup = try writeBackup(Data([1]), root: root)
        let input = root.appendingPathComponent("source.zip")
        let encrypted = root.appendingPathComponent("cancelled.vexbackup")
        let decrypted = root.appendingPathComponent("cancelled.zip")
        let password = password
        let cancelled = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try BackupCrypto.sealFile(input, to: encrypted, password: password)
                return false
            } catch is CancellationError {
                do {
                    _ = try BackupCrypto.unsealFile(backup, to: decrypted, password: password)
                    return false
                } catch is CancellationError { return true }
                catch { return false }
            } catch { return false }
        }.value
        XCTAssertTrue(cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: encrypted.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: decrypted.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".vexbackup-") })
    }

}

final class TweakBackupDurabilityTests: XCTestCase {
    private func fixture(_ body: (URL, URL, ManagedTweak, TweakFolder) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = TweakFolder(name: "Folder")
        let tweak = ManagedTweak(name: "Tweak", folderId: folder.id)
        try JSONEncoder().encode([folder]).write(to: source.appendingPathComponent("folders.json"))
        try JSONEncoder().encode([tweak]).write(to: source.appendingPathComponent("library.json"))
        let files = source.appendingPathComponent(tweak.id.uuidString)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        try Data([42]).write(to: files.appendingPathComponent("file"))
        try body(source, destination, tweak, folder)
    }

    func testLibraryFailureKeepsCommittedFoldersAndRollsBackOnlyNewFiles() throws {
        try fixture { source, destination, tweak, folder in
            var tweaks: [ManagedTweak] = []
            var folders: [TweakFolder] = []
            let existing = destination.appendingPathComponent("unrelated")
            try Data([7]).write(to: existing)
            XCTAssertThrowsError(try TweakBackupMerge.run(source: source, destination: destination,
                currentTweaks: tweaks, currentFolders: folders,
                write: { data, url in
                    if url.lastPathComponent == "library.json" { throw CocoaError(.fileWriteNoPermission) }
                    try data.write(to: url, options: .atomic)
                }, onFoldersCommitted: { folders = $0 }, onTweaksCommitted: { tweaks = $0 }))
            XCTAssertEqual(folders, [folder])
            XCTAssertTrue(tweaks.isEmpty)
            XCTAssertEqual(try JSONDecoder().decode([TweakFolder].self, from: Data(contentsOf: destination.appendingPathComponent("folders.json"))), [folder])
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent(tweak.id.uuidString).path))
            XCTAssertEqual(try Data(contentsOf: existing), Data([7]))
        }
    }

    func testFolderWriteFailureDoesNotPublishOrCopy() throws {
        try fixture { source, destination, tweak, _ in
            var folders: [TweakFolder] = []
            XCTAssertThrowsError(try TweakBackupMerge.run(source: source, destination: destination,
                currentTweaks: [], currentFolders: [], write: { _, _ in throw CocoaError(.fileWriteNoPermission) },
                onFoldersCommitted: { folders = $0 }, onTweaksCommitted: { _ in XCTFail("must not publish") }))
            XCTAssertTrue(folders.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent(tweak.id.uuidString).path))
        }
    }

    func testExistingOrphanIsNotAdoptedOrDeleted() throws {
        try fixture { source, destination, tweak, _ in
            let orphan = destination.appendingPathComponent(tweak.id.uuidString)
            try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
            try Data([9]).write(to: orphan.appendingPathComponent("unrelated"))
            XCTAssertThrowsError(try TweakBackupMerge.run(source: source, destination: destination,
                currentTweaks: [], currentFolders: [], onFoldersCommitted: { _ in }, onTweaksCommitted: { _ in XCTFail("must not publish") }))
            XCTAssertEqual(try Data(contentsOf: orphan.appendingPathComponent("unrelated")), Data([9]))
        }
    }

    func testSuccessfulRestorePersistsAndPublishes() throws {
        try fixture { source, destination, tweak, folder in
            var tweaks: [ManagedTweak] = []
            var folders: [TweakFolder] = []
            let count = try TweakBackupMerge.run(source: source, destination: destination,
                currentTweaks: [], currentFolders: [], onFoldersCommitted: { folders = $0 }, onTweaksCommitted: { tweaks = $0 })
            XCTAssertEqual(count, 1)
            XCTAssertEqual(tweaks, [tweak])
            XCTAssertEqual(folders, [folder])
            XCTAssertEqual(try JSONDecoder().decode([ManagedTweak].self, from: Data(contentsOf: destination.appendingPathComponent("library.json"))), [tweak])
        }
    }
}

final class CertificateExportScratchTests: XCTestCase {
    func testSuccessfulExportRemovesUnpackedSecrets() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let p12 = root.appendingPathComponent("source.p12")
        let profile = root.appendingPathComponent("source.mobileprovision")
        try Data([1]).write(to: p12)
        try Data([2]).write(to: profile)
        let scratch = root.appendingPathComponent("export")
        let result = CertificateExporter.package(p12: p12, provision: profile, password: "secret", name: "Example", directory: scratch) { inputs, output in
            XCTAssertEqual(inputs.count, 3)
            XCTAssertEqual(try String(contentsOf: inputs[2], encoding: .utf8), "secret")
            try Data([3]).write(to: output)
        }
        XCTAssertNotNil(result)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: scratch.path), ["Example.zip"])
        XCTAssertTrue(fm.fileExists(atPath: p12.path))
    }

    func testFailedExportRemovesCreatedScratchButNeverExistingDestination() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let p12 = root.appendingPathComponent("source.p12"), profile = root.appendingPathComponent("source.mobileprovision")
        try Data([1]).write(to: p12)
        try Data([2]).write(to: profile)
        let scratch = root.appendingPathComponent("export")
        XCTAssertNil(CertificateExporter.package(p12: p12, provision: profile, password: "secret", name: "Example", directory: scratch) { _, _ in
            throw CocoaError(.fileWriteNoPermission)
        })
        XCTAssertFalse(fm.fileExists(atPath: scratch.path))
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        let unrelated = scratch.appendingPathComponent("unrelated")
        try Data([9]).write(to: unrelated)
        XCTAssertNil(CertificateExporter.package(p12: p12, provision: profile, password: "secret", name: "Example", directory: scratch))
        XCTAssertEqual(try Data(contentsOf: unrelated), Data([9]))
    }
}
