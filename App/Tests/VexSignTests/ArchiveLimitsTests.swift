//
//  ArchiveLimitsTests.swift
//  VexSignTests
//
//  The archive-wide pass now has explicit bounds instead of two fixed numbers: one entry can no
//  longer be arbitrarily large, a path can no longer be arbitrarily deep, and an entry whose
//  expansion is out of proportion to its compressed size is rejected. Each test lowers one bound
//  and proves it fires, so no fixture has to be gigabytes to prove the rule.
//

import Foundation
import XCTest
import ZIPFoundation
@testable import VexSign

final class ArchiveLimitsTests: XCTestCase {
    private struct Entry {
        let path: String
        var size: Int = 1024
        var fill: UInt8 = 0x61
        var method: CompressionMethod = .none
        var isDirectory: Bool = false
    }

    private func withArchive(_ entries: [Entry], _ body: (URL) throws -> Void) throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("ArchiveLimits-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: root) } // try? ok: fixture cleanup, nothing to report
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        // Directory entries come from real folders, so the fixture does not depend on the
        // provider-based writer accepting an empty body for a folder.
        let input = root.appendingPathComponent("input", isDirectory: true)
        try manager.createDirectory(at: input, withIntermediateDirectories: true)
        let archiveURL = root.appendingPathComponent("Test.ipa")
        let archive = try Archive(url: archiveURL, accessMode: .create)
        for entry in entries {
            if entry.isDirectory {
                try manager.createDirectory(
                    at: input.appendingPathComponent(entry.path),
                    withIntermediateDirectories: true
                )
                try archive.addEntry(with: entry.path, relativeTo: input)
                continue
            }
            let fill = entry.fill
            try archive.addEntry(
                with: entry.path,
                type: .file,
                uncompressedSize: UInt32(entry.size),
                modificationDate: Date(),
                permissions: 0o644,
                compressionMethod: entry.method,
                provider: { _, size in Data(repeating: fill, count: size) }
            )
        }
        try body(archiveURL)
    }

    /// The shape of a real, harmless IPA: a payload folder and a small binary.
    private var harmless: [Entry] {
        [
            Entry(path: "Payload/", isDirectory: true),
            Entry(path: "Payload/Test.app/", isDirectory: true),
            Entry(path: "Payload/Test.app/Info.plist", size: 512),
            Entry(path: "Payload/Test.app/Test", size: 4096)
        ]
    }

    // MARK: - Bounds that must fire

    func testOversizedEntryIsRejected() throws {
        try withArchive(harmless + [Entry(path: "Payload/Test.app/big.bin", size: 2 * 1024 * 1024)]) { url in
            var limits = ArchiveSafetyValidator.Limits.default
            limits.maxEntryBytes = 1024 * 1024
            XCTAssertThrowsError(try ArchiveSafetyValidator.validate(url, limits: limits)) { error in
                guard case .some(.tooLarge) = error as? ArchiveSafetyValidator.ValidationError else {
                    return XCTFail("expected tooLarge, got \(error)")
                }
            }
        }
    }

    func testBombShapedEntryIsRejectedByRatio() throws {
        // 2 MiB of zeros deflates to a few kilobytes: ~1000:1, which no real payload does.
        let bomb = Entry(path: "Payload/Test.app/blob", size: 2 * 1024 * 1024, method: .deflate)
        try withArchive(harmless + [bomb]) { url in
            var limits = ArchiveSafetyValidator.Limits.default
            limits.maxCompressionRatio = 10
            limits.ratioFloorBytes = 1024
            XCTAssertThrowsError(try ArchiveSafetyValidator.validate(url, limits: limits)) { error in
                guard case .some(.suspiciousCompression(let path)) = error as? ArchiveSafetyValidator.ValidationError else {
                    return XCTFail("expected suspiciousCompression, got \(error)")
                }
                XCTAssertEqual(path, "Payload/Test.app/blob")
            }
        }
    }

    func testRatioFloorExemptsSmallCompressibleFiles() throws {
        let fluffy = Entry(path: "Payload/Test.app/blob", size: 2 * 1024 * 1024, method: .deflate)
        try withArchive(harmless + [fluffy]) { url in
            // The default floor is 64 MiB: an entry below it is never judged by ratio, because
            // real apps do contain small files that compress enormously.
            XCTAssertNoThrow(try ArchiveSafetyValidator.validate(url))
        }
    }

    func testDeepPathIsRejected() throws {
        let deep = (0..<12).map { "level\($0)" }.joined(separator: "/")
        try withArchive(harmless + [Entry(path: "Payload/Test.app/\(deep)/file", size: 128)]) { url in
            var limits = ArchiveSafetyValidator.Limits.default
            limits.maxDepth = 8
            XCTAssertThrowsError(try ArchiveSafetyValidator.validate(url, limits: limits)) { error in
                guard case .some(.excessiveDepth) = error as? ArchiveSafetyValidator.ValidationError else {
                    return XCTFail("expected excessiveDepth, got \(error)")
                }
            }
        }
    }

    func testEntryCountLimitIsEnforced() throws {
        try withArchive(harmless) { url in
            var limits = ArchiveSafetyValidator.Limits.default
            limits.maxEntries = 2
            XCTAssertThrowsError(try ArchiveSafetyValidator.validate(url, limits: limits)) { error in
                guard case .some(.tooManyEntries) = error as? ArchiveSafetyValidator.ValidationError else {
                    return XCTFail("expected tooManyEntries, got \(error)")
                }
            }
        }
    }

    func testExpandedTotalLimitIsEnforced() throws {
        try withArchive(harmless) { url in
            var limits = ArchiveSafetyValidator.Limits.default
            limits.maxExpandedBytes = 1024
            XCTAssertThrowsError(try ArchiveSafetyValidator.validate(url, limits: limits)) { error in
                guard case .some(.tooLarge) = error as? ArchiveSafetyValidator.ValidationError else {
                    return XCTFail("expected tooLarge, got \(error)")
                }
            }
        }
    }

    // MARK: - Bounds that must not fire

    func testOrdinaryArchivePassesEveryDefaultBound() throws {
        try withArchive(harmless) { url in
            XCTAssertNoThrow(try ArchiveSafetyValidator.validate(url))
        }
    }

    func testDefaultsAreSaneAndNotAccidentallyTiny() {
        let limits = ArchiveSafetyValidator.Limits.default
        XCTAssertGreaterThanOrEqual(limits.maxEntries, 10_000)
        XCTAssertGreaterThanOrEqual(limits.maxExpandedBytes, 2 * 1024 * 1024 * 1024)
        XCTAssertGreaterThanOrEqual(limits.maxEntryBytes, 1024 * 1024 * 1024)
        XCTAssertGreaterThanOrEqual(limits.maxDepth, 32)
        XCTAssertGreaterThan(limits.maxCompressionRatio, 50)
        XCTAssertGreaterThanOrEqual(limits.ratioFloorBytes, 16 * 1024 * 1024)
    }

    func testRatioRuleIgnoresStoredAndTinyEntries() {
        let limits = ArchiveSafetyValidator.Limits.default
        // Stored entry: expanded == compressed, so the ratio is 1 whatever the size.
        XCTAssertFalse(limits.exceedsRatio(expanded: 900 * 1024 * 1024, compressed: 900 * 1024 * 1024))
        // Zero compressed size cannot be divided; the entry is left to the size bounds.
        XCTAssertFalse(limits.exceedsRatio(expanded: 900 * 1024 * 1024, compressed: 0))
        // Below the floor, even an absurd ratio is not a bomb.
        XCTAssertFalse(limits.exceedsRatio(expanded: 1024, compressed: 1))
        // Above the floor and past the ratio, it is.
        XCTAssertTrue(limits.exceedsRatio(expanded: 512 * 1024 * 1024, compressed: 1024 * 1024))
    }

    func testDirectoryEntriesDoNotCountTowardDepthBeyondTheirOwnPath() throws {
        let path = "Payload/Test.app"
        try withArchive([Entry(path: path, isDirectory: true), Entry(path: "\(path)/Test", size: 64)]) { url in
            var limits = ArchiveSafetyValidator.Limits.default
            limits.maxDepth = 3
            XCTAssertNoThrow(try ArchiveSafetyValidator.validate(url, limits: limits))
        }
    }
}
