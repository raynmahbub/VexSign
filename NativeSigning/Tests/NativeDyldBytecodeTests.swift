import Foundation
import XCTest
@testable import NativeSigningLinkSmoke

/// Deferred synthetic pointer/bytecode contexts only, no real image, runtime
/// pointer writes, dylib loads, signing, trust or platform acceptance.
final class NativeDyldBytecodeTests: XCTestCase {
    private static let segments: [NativeDyldSegment] = [
        .init(file: 0..<16, address: 0x1000, vmSize: 16, writable: false, executable: true),
        .init(file: 16..<64, address: 0x2000, vmSize: 48, writable: true, executable: false)
    ]
    private static func image() -> Data {
        var data = Data(repeating: 0, count: 64)
        for (position, value) in [(16, UInt64(0x1008)), (32, UInt64(0x100c))] {
            for i in 0..<8 { data[position + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
        }
        return data
    }
    private static func bind(offset: UInt8 = 8, symbol: String = "_fixture") -> Data {
        Data([0x11, 0x40]) + Data(symbol.utf8) + Data([0, 0x71, offset, 0x90, 0])
    }
    private static func validate(rebase: Data = Data(), bind: Data = Data(), lazy: Data = Data(), image: Data = NativeDyldBytecodeTests.image(), segments: [NativeDyldSegment] = NativeDyldBytecodeTests.segments) throws {
        try NativeDyldBytecode.validate(rebase: rebase, bind: bind, lazyBind: lazy, image: image,
            segments: segments, dependencyCount: 1, signatureOffset: 64)
    }
    func testRegularRebaseBindAndSharedRebaseLazyPointer() throws {
        let rebase = Data([0x11, 0x21, 0, 0x51, 0x30, 8, 0x51, 0])
        try Self.validate(rebase: rebase, bind: Self.bind(), lazy: Self.bind(offset: 16))
    }
    func testCountSkipRebaseAndMultipleLazyRecords() throws {
        try Self.validate(rebase: Data([0x11, 0x21, 0, 0x80, 2, 8, 0]))
        try Self.validate(lazy: Self.bind(offset: 8) + Self.bind(offset: 24))
    }
    func testStateWithoutOrdinalSymbolSegmentOrTypeRejects() throws {
        for stream in [Data([0x90, 0]), Data([0x11, 0x71, 8, 0x90, 0]), Data([0x40, 95, 120, 0, 0x71, 8, 0x90, 0])] {
            XCTAssertThrowsError(try Self.validate(bind: stream))
        }
        XCTAssertThrowsError(try Self.validate(rebase: Data([0x21, 0, 0x51, 0])))
    }
    func testUnalignedExecutableOutOfBoundsAndDuplicateWritesReject() throws {
        for offset in [UInt8(1), 47, 48, 127] { XCTAssertThrowsError(try Self.validate(bind: Self.bind(offset: offset))) }
        let text = Data([0x11, 0x40, 95, 120, 0, 0x70, 0, 0x90, 0])
        XCTAssertThrowsError(try Self.validate(bind: text))
        XCTAssertThrowsError(try Self.validate(lazy: Self.bind() + Self.bind()))
        let duplicateRebase = Data([0x11, 0x21, 0, 0x51, 0x21, 0, 0x51, 0])
        XCTAssertThrowsError(try Self.validate(rebase: duplicateRebase))
    }
    func testULEBOverflowNonminimalTruncationAndMissingDoneReject() throws {
        let prefix = Data([0x11, 0x40, 95, 120, 0, 0x71])
        for operand in [Data([0x80]), Data([0x88, 0]), Data(repeating: 0xff, count: 10), Data([0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 2])] {
            XCTAssertThrowsError(try Self.validate(bind: prefix + operand))
        }
        XCTAssertThrowsError(try Self.validate(bind: Data(Self.bind().dropLast())))
        XCTAssertThrowsError(try Self.validate(rebase: Data([0x11, 0x21, 0, 0x51])))
    }
    func testUnsupportedThreadedSpecialWeakAddendAndNonPointerFormsReject() throws {
        for opcode in [UInt8(0x30), 0x41, 0x52, 0x60, 0xd0, 0xf0] {
            XCTAssertThrowsError(try Self.validate(bind: Data([opcode, 0])))
        }
        XCTAssertThrowsError(try Self.validate(bind: Data([0x12, 0])))
        XCTAssertThrowsError(try Self.validate(rebase: Data([0x12, 0])))
    }
    func testUnterminatedOrOversizedSymbolAndHiddenAfterDoneReject() throws {
        XCTAssertThrowsError(try Self.validate(bind: Data([0x11, 0x40, 95])))
        XCTAssertThrowsError(try Self.validate(bind: Self.bind(symbol: String(repeating: "a", count: 1025))))
        XCTAssertThrowsError(try Self.validate(bind: Self.bind() + Data([0x11])))
        try Self.validate(bind: Self.bind() + Data(repeating: 0, count: 7))
        XCTAssertThrowsError(try Self.validate(bind: Self.bind() + Data(repeating: 0, count: 8)))
    }
    func testForeignPointerAndNonzeroRegularBindingSlotReject() throws {
        var image = Self.image(); image[23] = 255
        XCTAssertThrowsError(try Self.validate(rebase: Data([0x11, 0x21, 0, 0x51, 0]), image: image))
        XCTAssertThrowsError(try Self.validate(bind: Self.bind(offset: 0)))
    }
}
