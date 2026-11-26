import Foundation
import XCTest
import ZIPFoundation
@testable import VexSign

final class IPAExtractorTests: XCTestCase {
    private func fixture(_ body: (URL, URL, Data) throws -> Void) throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? manager.removeItem(at: root) }
        let input = root.appendingPathComponent("input")
        let app = input.appendingPathComponent("Payload/Test.app")
        try manager.createDirectory(at: app, withIntermediateDirectories: true)
        let bytes = Data(repeating: 0x61, count: 2 * 1024 * 1024 + 17)
        try bytes.write(to: app.appendingPathComponent("Test"))
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: app.appendingPathComponent("Test").path)
        let archiveURL = root.appendingPathComponent("Test.ipa")
        do {
            let archive = try Archive(url: archiveURL, accessMode: .create)
            for path in ["Payload/", "Payload/Test.app/", "Payload/Test.app/Test"] {
                try archive.addEntry(with: path, relativeTo: input, compressionMethod: .none)
            }
        }
        try body(archiveURL, root.appendingPathComponent("output"), bytes)
    }

    func testArchiveCopyChecksCancellationBetweenChunks() throws {
        try fixture { source, output, _ in
            var checkpoints = 0
            XCTAssertThrowsError(try AppFileHandler.copyArchive(from: source, to: output) {
                checkpoints += 1
                if checkpoints == 3 { throw CancellationError() }
            }) { XCTAssertTrue($0 is CancellationError) }
            let copied = try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber
            let original = try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber
            XCTAssertLessThan(try XCTUnwrap(copied).int64Value, try XCTUnwrap(original).int64Value)
        }
    }

    func testArchiveCopyPreservesBytes() throws {
        try fixture { source, output, _ in
            try AppFileHandler.copyArchive(from: source, to: output, checkpoint: {})
            XCTAssertEqual(try Data(contentsOf: output), try Data(contentsOf: source))
        }
    }

    func testRoundTripPreservesBytesExecutableModeAndMonotonicProgress() throws {
        try fixture { source, output, bytes in
            var values: [Double] = []
            try IPAExtractor.extract(source, to: output, progress: { values.append($0) })
            let binary = output.appendingPathComponent("Payload/Test.app/Test")
            XCTAssertEqual(try Data(contentsOf: binary), bytes)
            let mode = try FileManager.default.attributesOfItem(atPath: binary.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual((mode?.intValue ?? 0) & 0o777, 0o755)
            XCTAssertEqual(values.first, 0)
            XCTAssertEqual(values.last, 1)
            XCTAssertEqual(values, values.sorted())
            XCTAssertLessThanOrEqual(values.count, 102)
        }
    }

    func testCancellationBeforeExtractionWritesNothing() throws {
        try fixture { source, output, _ in
            XCTAssertThrowsError(try IPAExtractor.extract(source, to: output, checkpoint: {
                throw CancellationError()
            })) { XCTAssertTrue($0 is CancellationError) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
    }

    func testCancellationDuringArchiveValidationWritesNothing() throws {
        try fixture { source, output, _ in
            var checkpoints = 0
            XCTAssertThrowsError(try IPAExtractor.extract(source, to: output, checkpoint: {
                checkpoints += 1
                if checkpoints == 3 { throw CancellationError() }
            })) { XCTAssertTrue($0 is CancellationError) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
    }

    func testCancellationDuringLargeEntryStopsBeforeCompletion() throws {
        try fixture { source, output, bytes in
            var checkpoints = 0
            var progress: [Double] = []
            XCTAssertThrowsError(try IPAExtractor.extract(source, to: output, checkpoint: {
                checkpoints += 1
                if checkpoints == 10 { throw CancellationError() }
            }, progress: { progress.append($0) })) { XCTAssertTrue($0 is CancellationError) }
            XCTAssertFalse(progress.contains(1))
            let binary = output.appendingPathComponent("Payload/Test.app/Test")
            let size = try FileManager.default.attributesOfItem(atPath: binary.path)[.size] as? NSNumber
            XCTAssertLessThan(size?.intValue ?? Int.max, bytes.count)
        }
    }

    func testChecksumMismatchNeverReportsCompletion() throws {
        try fixture { source, output, bytes in
            var archive = try Data(contentsOf: source)
            let marker = Data(bytes.prefix(64))
            let range = try XCTUnwrap(archive.range(of: marker))
            archive[range.lowerBound] ^= 0xff
            try archive.write(to: source)
            var completed = false
            XCTAssertThrowsError(try IPAExtractor.extract(source, to: output, progress: { completed = $0 == 1 })) { error in
                guard case IPAExtractor.ExtractionError.checksum = error else {
                    return XCTFail("Expected CRC mismatch, got \(error)")
                }
            }
            XCTAssertFalse(completed)
        }
    }

    func testExistingOutputFileIsNotOverwritten() throws {
        try fixture { source, output, _ in
            let binary = output.appendingPathComponent("Payload/Test.app/Test")
            try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
            let original = Data("keep me".utf8)
            try original.write(to: binary)
            XCTAssertThrowsError(try IPAExtractor.extract(source, to: output))
            XCTAssertEqual(try Data(contentsOf: binary), original)
        }
    }

    func testImportPayloadRequiresExactlyOneTopLevelAppDirectory() throws {
        try fixture { _, output, _ in
            let fm = FileManager.default
            try fm.createDirectory(at: output, withIntermediateDirectories: true)
            XCTAssertThrowsError(try IPAImportPayload.application(in: output)) { error in
                guard case IPAImportPayload.ValidationError.missingApp = error else {
                    return XCTFail("Expected missing app, got \(error)")
                }
            }
            let app = output.appendingPathComponent("First.app", isDirectory: true)
            try fm.createDirectory(at: app, withIntermediateDirectories: true)
            // Nested watch apps and extensions must not count as top-level apps.
            try fm.createDirectory(at: app.appendingPathComponent("Watch/Watch.app"), withIntermediateDirectories: true)
            XCTAssertEqual(try IPAImportPayload.application(in: output), app)
            try fm.createDirectory(at: output.appendingPathComponent("Second.app"), withIntermediateDirectories: true)
            XCTAssertThrowsError(try IPAImportPayload.application(in: output)) { error in
                guard case IPAImportPayload.ValidationError.multipleApps = error else {
                    return XCTFail("Expected multiple apps, got \(error)")
                }
            }
        }
    }

    func testImportPayloadRejectsAFileMasqueradingAsAnApp() throws {
        try fixture { _, output, _ in
            let fm = FileManager.default
            try fm.createDirectory(at: output, withIntermediateDirectories: true)
            try Data("not a directory".utf8).write(to: output.appendingPathComponent("Fake.app"))
            XCTAssertThrowsError(try IPAImportPayload.application(in: output)) { error in
                guard case IPAImportPayload.ValidationError.invalidApp = error else {
                    return XCTFail("Expected invalid app, got \(error)")
                }
            }
        }
    }

    func testImportPayloadValidatesMetadataAndExecutableBeforeRegistration() throws {
        try fixture { _, output, _ in
            let fm = FileManager.default
            let app = output.appendingPathComponent("Test.app", isDirectory: true)
            try fm.createDirectory(at: app, withIntermediateDirectories: true)
            let plist = app.appendingPathComponent("Info.plist")
            func writeInfo(_ info: [String: Any]) throws {
                let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                try data.write(to: plist)
            }
            func assertInvalid(_ expected: IPAImportPayload.ValidationError, file: StaticString = #filePath, line: UInt = #line) {
                XCTAssertThrowsError(try IPAImportPayload.validateApplication(in: output), file: file, line: line) { error in
                    XCTAssertEqual(error as? IPAImportPayload.ValidationError, expected, file: file, line: line)
                }
            }

            assertInvalid(.invalidMetadata)
            try Data("not a plist".utf8).write(to: plist)
            assertInvalid(.invalidMetadata)
            try writeInfo(["CFBundleExecutable": "Test"])
            assertInvalid(.invalidIdentifier)
            try writeInfo(["CFBundleIdentifier": "  ", "CFBundleExecutable": "Test"])
            assertInvalid(.invalidIdentifier)
            try writeInfo(["CFBundleIdentifier": "example.test", "CFBundleExecutable": "Test"])
            assertInvalid(.invalidExecutable)
            try Data([0xcf, 0xfa, 0xed, 0xfe]).write(to: app.appendingPathComponent("Test"))
            XCTAssertEqual(try IPAImportPayload.validateApplication(in: output), app)
            try writeInfo(["CFBundleIdentifier": "example.test", "CFBundleExecutable": "../Test"])
            assertInvalid(.invalidExecutable)
        }
    }

    func testExpiredDeadlineWritesNothing() throws {
        try fixture { source, output, _ in
            XCTAssertThrowsError(try IPAExtractor.extract(source, to: output, timeout: 0)) { error in
                guard case IPAExtractor.ExtractionError.timedOut = error else {
                    return XCTFail("Expected extraction deadline, got \(error)")
                }
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
    }
}
