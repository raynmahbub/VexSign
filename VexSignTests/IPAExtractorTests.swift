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

    func testCancellationDuringLargeEntryStopsBeforeCompletion() throws {
        try fixture { source, output, bytes in
            var checkpoints = 0
            var progress: [Double] = []
            XCTAssertThrowsError(try IPAExtractor.extract(source, to: output, checkpoint: {
                checkpoints += 1
                if checkpoints == 7 { throw CancellationError() }
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
