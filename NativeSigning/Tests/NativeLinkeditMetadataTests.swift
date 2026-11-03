import Foundation
import XCTest
@testable import NativeSigningLinkSmoke

/// Deferred synthetic metadata/layout vectors, not instruction execution,
/// signed archive acceptance, native trust or installation tests.
final class NativeLinkeditMetadataTests: XCTestCase {
    private static func entry(_ start: Int, length: Int, kind: Int) -> Data {
        var bytes = Data((0..<4).map { UInt8(truncatingIfNeeded: start >> ($0 * 8)) })
        bytes += Data([UInt8(truncatingIfNeeded: length), UInt8(truncatingIfNeeded: length >> 8), UInt8(truncatingIfNeeded: kind), UInt8(truncatingIfNeeded: kind >> 8)])
        return bytes
    }
    func testCanonicalFunctionStartsAndPadding() throws {
        let image = NativeMachOMutationTests.image()
        try NativeLinkeditMetadata.functions(Data([0x80, 4, 4, 0]), image: image) // 512, 516
        try NativeLinkeditMetadata.functions(Data([0]), image: image)
        try NativeLinkeditMetadata.functions(Data(), image: image)
    }
    func testMalformedNonInstructionOrUnalignedFunctionStartsReject() throws {
        let image = NativeMachOMutationTests.image()
        let cases: [[UInt8]] = [[1, 0], [0x81, 4, 0], [0x80, 8, 0], [0x80, 4], [0x80], [0x80, 0, 0]]
        for bytes in cases {
            XCTAssertThrowsError(try NativeLinkeditMetadata.functions(Data(bytes), image: image))
        }
        XCTAssertThrowsError(try NativeLinkeditMetadata.functions(Data([0]) + Data(repeating: 0, count: 8), image: image))
    }
    func testBoundedDataAndJumpTableKinds() throws {
        let image = NativeMachOMutationTests.image()
        for kind in 1...5 {
            try NativeLinkeditMetadata.dataInCode(Self.entry(512, length: 4, kind: kind), image: image)
        }
    }
    func testDataKindsAlignmentOverlapAndRangeReject() throws {
        let image = NativeMachOMutationTests.image()
        for entry in [Self.entry(512, length: 0, kind: 1), Self.entry(512, length: 4, kind: 6),
                      Self.entry(1024, length: 4, kind: 1), Self.entry(513, length: 4, kind: 4),
                      Self.entry(512, length: 3, kind: 3), Data([1])] {
            XCTAssertThrowsError(try NativeLinkeditMetadata.dataInCode(entry, image: image))
        }
        let overlap = Self.entry(512, length: 8, kind: 1) + Self.entry(516, length: 4, kind: 1)
        XCTAssertThrowsError(try NativeLinkeditMetadata.dataInCode(overlap, image: image))
    }
}
