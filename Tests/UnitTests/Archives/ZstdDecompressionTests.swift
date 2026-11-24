//
//  ZstdDecompressionTests.swift
//  VexSignTests
//
//  zstd is what a modern `.deb` payload is compressed with, and iOS ships no decoder for it, so
//  these fixtures are the only thing standing between `data.tar.zst` and an "unsupported format"
//  refusal. The frames were produced by the reference `zstandard` implementation, not by the
//  code under test.
//

import XCTest
@testable import VexSign

final class ZstdDecompressionTests: XCTestCase {
    /// 900 bytes of text, level 9, with a content checksum and a declared size.
    private static let textFrame = """
    KLUv/WSEAnUCAGKEEBiAxTqERJDtXyH6X0C2CGIoQzkSwTmJnQYPTuthTLQW0GdKcchfm6dAr+KJwW75Hu3CLtcem2s2gqmujcWnw8NbIgIANp1QiEWroL2rm4Q=
    """

    /// A real `data.tar` (two files) at level 19 with a checksum: 10240 bytes → 210.
    private static let tarFrame = """
    KLUv/WQAJyUGAAIJICCguwEorLr6//83MIzWcD6TU9efGpj2uRk6eruZJf8H7jHSI0aKrb6vHNtKz0P0oAcCeCABg6o+Y4vBO2UIFQopdf5rPahWd1cLwqjbOO25P1x1vp7DN+fggkv3Nyfhz/m7ocDiS2evxGz/+alSO4lWV6yzczX2vlMxceOKnV8CGCCwSKoqMQ7Njx7IZ5ACKHzFB6kH8AApCRq6q42hYmfMQdUBJArjqGNxvQ16jqkDWLqlBs9hFgEGPcCoxi6wnwci7GY/
    """

    /// Two independent frames in one stream, as the format allows.
    private static let concatenatedFrames = "KLUv/SAMYQAAZmlyc3QgZnJhbWU7KLUv/SANaQAAc2Vjb25kIGZyYW1lOw=="

    /// The text frame with one bit flipped in its 4-byte checksum.
    private static let corruptChecksumFrame = """
    KLUv/WSEAnUCAGKEEBiAxTqERJDtXyH6X0C2CGIoQzkSwTmJnQYPTuthTLQW0GdKcchfm6dAr+KJwW75Hu3CLtcem2s2gqmujcWnw8NbIgIANp1QiEWroL2rm3s=
    """

    private func data(_ base64: String) throws -> Data {
        try XCTUnwrap(Data(base64Encoded: base64.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZstdTest-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: - Decoding

    func testDecodesAFrameAndVerifiesItsChecksum() throws {
        let decoded = try ZstdDecompression.decompress(try data(Self.textFrame), limit: 1 << 20)
        XCTAssertEqual(decoded.count, 900)
        let text = try XCTUnwrap(String(data: decoded, encoding: .utf8))
        XCTAssertTrue(text.hasPrefix("VexSign zstd payload fixture: the quick brown fox"))
        XCTAssertTrue(text.hasSuffix("jumps over the lazy dog. "))
    }

    func testDecodesConcatenatedFrames() throws {
        let decoded = try ZstdDecompression.decompress(try data(Self.concatenatedFrames), limit: 1 << 20)
        XCTAssertEqual(String(data: decoded, encoding: .utf8), "first frame;second frame;")
    }

    func testRefusesAFrameWhoseChecksumDoesNotMatch() throws {
        // The payload decompresses; only the checksum says it is not the bytes that were
        // written, which is exactly the case a torn `.deb` download produces.
        XCTAssertThrowsError(try ZstdDecompression.decompress(try data(Self.corruptChecksumFrame), limit: 1 << 20)) { error in
            let message = error.localizedDescription.lowercased()
            XCTAssertTrue(message.contains("zstd"), message)
        }
    }

    func testRefusesOutputBeyondTheLimit() throws {
        // The frame declares 900 bytes, so the ceiling is refused before a page is allocated.
        XCTAssertThrowsError(try ZstdDecompression.decompress(try data(Self.textFrame), limit: 512)) { error in
            guard case ArchiveExtractionError.expandedTooLarge = error else {
                return XCTFail("Expected expandedTooLarge, got \(error)")
            }
        }
    }

    func testRefusesGarbageRatherThanReturningEmptyData() throws {
        let garbage = Data("not a zstd frame at all".utf8)
        XCTAssertThrowsError(try ZstdDecompression.decompress(garbage, limit: 1 << 20))
    }

    // MARK: - The path a `.deb` member travels

    func testExtractsAZstdDebianDataArchive() throws {
        let directory = try temporaryDirectory()
        var member = directory.appendingPathComponent("data.tar.zst")
        try (try data(Self.tarFrame)).write(to: member)

        // First pass: decompress `data.tar.zst` → `data.tar`.
        try extractFile(at: &member)
        XCTAssertEqual(member.lastPathComponent, "data.tar")

        // Second pass: untar it, exactly as `DebianDataMember.extract` does.
        try extractFile(at: &member)
        let dylib = member.appendingPathComponent("Library/MobileSubstrate/DynamicLibraries/Fixture.dylib")
        let bytes = try Data(contentsOf: dylib)
        XCTAssertEqual(Array(bytes.prefix(4)), [0xCF, 0xFA, 0xED, 0xFE], "The payload must survive both passes")
        let plist = member.appendingPathComponent("Library/MobileSubstrate/DynamicLibraries/Fixture.plist")
        XCTAssertTrue(try Data(contentsOf: plist).starts(with: Data("<?xml".utf8)))
    }

    func testDebianSelectionAcceptsZstdAndRefusesUnknownCompression() throws {
        let names = ["debian-binary", "control.tar.gz", "data.tar.zst"]
        XCTAssertEqual(try DebianDataMember.select(from: names), "data.tar.zst")

        XCTAssertThrowsError(try DebianDataMember.select(from: ["debian-binary", "data.tar.lz4"])) { error in
            XCTAssertEqual(error as? DebianDataMember.SelectionError, .unsupported("data.tar.lz4"))
        }
    }
}
