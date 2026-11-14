import Foundation
import XCTest
@testable import NativeSigningLinkSmoke

/// Deferred synthetic chain fixtures only. No actual dyld pointer writes, symbol
/// lookup, signing, native platform or certificate/install trust is exercised.
final class NativeChainedFixupsTests: XCTestCase {
    private static let segments: [NativeDyldSegment] = [
        .init(file: 0..<4096, address: 0x100000000, vmSize: 4096, writable: false, executable: true),
        .init(file: 4096..<8192, address: 0x100001000, vmSize: 4096, writable: true, executable: false)
    ]
    private static func put(_ value: UInt64, _ p: Int, _ count: Int = 4, in data: inout Data) {
        for i in 0..<count { data[p + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
    }
    private static func fixture() -> (Data, Data) {
        var payload = Data(repeating: 0, count: 68)
        for (p, value) in [(4, 28), (8, 64), (12, 68), (16, 1), (20, 1), (28, 2), (36, 12), (40, 24), (64, 1)] {
            put(UInt64(value), p, in: &payload)
        }
        put(4096, 44, 2, in: &payload); put(6, 46, 2, in: &payload)
        put(4096, 48, 8, in: &payload); put(1, 60, 2, in: &payload)
        payload += Data("_fixture".utf8) + Data([0])
        var image = Data(repeating: 0, count: 8192)
        put((UInt64(2) << 51) | 8, 4096, 8, in: &image)
        put(UInt64(1) << 63, 4104, 8, in: &image)
        return (payload, image)
    }
    private static func verify(_ payload: Data, _ image: Data) throws {
        try NativeChainedFixups.validate(payload, image: image, segments: segments, dependencyCount: 1, signatureOffset: 8192)
    }
    func testLoaderUsesValidatedChainedHeaderAndImportPool() throws {
        var payload = Data(repeating: 0, count: 44)
        for (p, value) in [(4, 28), (8, 40), (12, 44), (16, 1), (20, 1), (28, 2), (40, 1)] {
            Self.put(UInt64(value), p, in: &payload)
        }
        payload += Data("_fixture".utf8) + Data([0])
        var command = Data(repeating: 0, count: 16)
        for (p, value) in [(0, 0x80000034), (4, 16), (8, 4096), (12, payload.count)] {
            Self.put(UInt64(value), p, in: &command)
        }
        var image = NativeMachOLoaderPolicyTests.image(extra: command, extraCount: 1)
        image.replaceSubrange(4096..<(4096 + payload.count), with: payload)
        try NativeMachOLoaderPolicy.validate(image)
        Self.put(2, 4096 + 20, in: &image) // unsupported import-addend format
        XCTAssertThrowsError(try NativeMachOLoaderPolicy.validate(image))
    }
    func testCanonicalRebaseAndImportBindingChain() throws {
        let (payload, image) = Self.fixture(); try Self.verify(payload, image)
    }
    func testUnsupportedHeaderFormatsWeakAndSpecialImportsReject() throws {
        let (payload, image) = Self.fixture()
        let cases: [(Int, UInt64)] = [(0, 1), (20, 2), (24, 1), (64, 0), (64, 255), (64, 257)]
        for (p, value) in cases {
            var changed = payload; Self.put(value, p, in: &changed)
            XCTAssertThrowsError(try Self.verify(changed, image))
        }
        var special = payload; Self.put(241, 64, in: &special)
        XCTAssertThrowsError(try NativeChainedFixups.validate(special, image: image,
            segments: Self.segments, dependencyCount: 253, signatureOffset: 8192))
    }
    func testAuthFormatMultiStartAndBadSegmentGeometryReject() throws {
        let (payload, image) = Self.fixture()
        let cases: [(Int, UInt64, Int)] = [(46, 1, 2), (62, 0x8000, 2), (62, 1, 2), (44, 1024, 2), (48, 0, 8), (56, 1, 4)]
        for (p, value, count) in cases {
            var changed = payload; Self.put(value, p, count, in: &changed)
            XCTAssertThrowsError(try Self.verify(changed, image))
        }
    }
    func testPointerReservedAddendOrdinalAndCrossPageNextReject() throws {
        let (payload, image) = Self.fixture()
        for value in [(UInt64(1) << 63) | 1, (UInt64(1) << 63) | (1 << 24), UInt64(1) << 44, UInt64(1) << 36,
                      (UInt64(1024) << 51) | 8, (UInt64(1) << 51) | 8] {
            var changed = image; Self.put(value, 4096, 8, in: &changed)
            XCTAssertThrowsError(try Self.verify(payload, changed))
        }
    }
    func testOverlappingStructuresHiddenNamesAndTruncationReject() throws {
        let (payload, image) = Self.fixture()
        var overlap = payload; Self.put(28, 8, in: &overlap)
        XCTAssertThrowsError(try Self.verify(overlap, image))
        XCTAssertThrowsError(try Self.verify(payload + Data("unused\0".utf8), image))
        for size in [0, 27, 28, 63, payload.count - 1] {
            XCTAssertThrowsError(try Self.verify(Data(payload.prefix(size)), image))
        }
    }
    func testImportNameMustBeCanonicalStringStart() throws {
        let (payload, image) = Self.fixture()
        var suffixAlias = payload; Self.put((1 << 9) | 1, 64, in: &suffixAlias)
        XCTAssertThrowsError(try Self.verify(suffixAlias, image))
        var nonASCII = payload; nonASCII[68] = 255
        XCTAssertThrowsError(try Self.verify(nonASCII, image))
    }
}
