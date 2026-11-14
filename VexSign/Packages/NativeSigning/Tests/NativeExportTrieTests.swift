import Foundation
import XCTest
@testable import NativeSigningLinkSmoke

/// Deferred synthetic export metadata only. No symbol resolution/runtime code,
/// dylib loading, signing, native platform trust or install acceptance.
final class NativeExportTrieTests: XCTestCase {
    private static let segments: [NativeDyldSegment] = [
        .init(file: 0..<16, address: 0x1000, vmSize: 16, writable: false, executable: true),
        .init(file: 16..<64, address: 0x2000, vmSize: 48, writable: true, executable: false)
    ]
    private static let simple = Data([0, 1, 95, 120, 0, 6, 2, 0, 8, 0])
    private static func verify(_ data: Data) throws {
        try NativeExportTrie.validate(data, segments: segments, signatureOffset: 64)
    }
    func testRegularWeakAndHeaderAddressExports() throws {
        try Self.verify(Self.simple)
        var weakExport = Self.simple; weakExport[7] = 4; try Self.verify(weakExport)
        var header = Self.simple; header[8] = 0; try Self.verify(header)
        try Self.verify(Data([0, 0]))
        try Self.verify(Data())
    }
    func testAddressMustBeInFileBackedImageAndKindsAreRestricted() throws {
        var outside = Self.simple; outside[8] = 127
        XCTAssertThrowsError(try Self.verify(outside))
        for flags in [UInt8(1), 2, 8, 16, 32, 0xff] {
            var data = Self.simple; data[7] = flags
            XCTAssertThrowsError(try Self.verify(data))
        }
    }
    func testTruncationOverflowAndNoncanonicalULEBReject() throws {
        for size in 1..<Self.simple.count { XCTAssertThrowsError(try Self.verify(Data(Self.simple.prefix(size)))) }
        XCTAssertThrowsError(try Self.verify(Data([0x80, 0, 0])))
        XCTAssertThrowsError(try Self.verify(Data(repeating: 0xff, count: 10)))
    }
    func testCycleSharedNodeAndOverlappingNodeReject() throws {
        XCTAssertThrowsError(try Self.verify(Data([0, 1, 120, 0, 0])))
        // Two disjoint edge names point at the same child, not a canonical tree.
        XCTAssertThrowsError(try Self.verify(Data([0, 2, 97, 0, 8, 98, 0, 8, 2, 0, 8, 0])))
        var overlap = Self.simple; overlap[5] = 2
        XCTAssertThrowsError(try Self.verify(overlap))
    }
    func testAmbiguousEdgePrefixesAndEmptyEdgesReject() throws {
        // Same first character could match two paths on lookup.
        let ambiguous = Data([0, 2, 97, 0, 9, 97, 98, 0, 13, 2, 0, 8, 0, 2, 0, 9, 0])
        XCTAssertThrowsError(try Self.verify(ambiguous))
        XCTAssertThrowsError(try Self.verify(Data([0, 1, 0, 4, 0, 0])))
    }
    func testHiddenInteriorPayloadAndExcessPaddingReject() throws {
        try Self.verify(Self.simple + Data(repeating: 0, count: 7))
        XCTAssertThrowsError(try Self.verify(Self.simple + Data(repeating: 0, count: 8)))
        XCTAssertThrowsError(try Self.verify(Self.simple + Data([1])))
        // One unreachable byte inserted before the leaf; child points past it.
        let gap = Data([0, 1, 95, 120, 0, 7, 0, 2, 0, 8, 0])
        XCTAssertThrowsError(try Self.verify(gap))
    }
}
