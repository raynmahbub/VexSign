import Foundation
import XCTest
@testable import VexSign

final class MachOReaderTests: XCTestCase {
    private func put(_ value: UInt32, at offset: Int, in data: inout Data, bigEndian: Bool = false) {
        let bytes = (0..<4).map { UInt8(truncatingIfNeeded: value >> UInt32((bigEndian ? 3 - $0 : $0) * 8)) }
        data.replaceSubrange(offset..<(offset + 4), with: bytes)
    }

    private func image(terminated: Bool = true) -> Data {
        var data = Data(repeating: 0, count: 96)
        put(MachOReader.machO64, at: 0, in: &data)
        put(1, at: 16, in: &data)
        put(64, at: 20, in: &data)
        put(0x0c, at: 32, in: &data)
        put(64, at: 36, in: &data)
        put(24, at: 40, in: &data)
        let name = Array("@rpath/Test.dylib".utf8)
        data.replaceSubrange(56..<(56 + name.count), with: name)
        if !terminated { for i in (56 + name.count)..<96 { data[i] = 65 } }
        return data
    }

    func testReadsValidLoadCommand() {
        XCTAssertEqual(MachOReader.dylibs(in: image()), ["@rpath/Test.dylib"])
    }

    func testRejectsCommandOutsideDeclaredRegion() {
        var data = image()
        put(8, at: 20, in: &data)
        XCTAssertTrue(MachOReader.dylibs(in: data).isEmpty)
    }

    func testRejectsNameInsideCommandHeaderAndUnterminatedName() {
        var data = image()
        put(8, at: 40, in: &data)
        XCTAssertTrue(MachOReader.dylibs(in: data).isEmpty)
        XCTAssertTrue(MachOReader.dylibs(in: image(terminated: false)).isEmpty)
    }

    func testRejectsExcessiveCommandCount() {
        var data = image()
        put(UInt32.max, at: 16, in: &data)
        XCTAssertTrue(MachOReader.dylibs(in: data).isEmpty)
    }

    func testFat64DoesNotTruncateHighOffsetBits() {
        var data = Data(repeating: 0, count: 160)
        put(MachOReader.fat64, at: 0, in: &data, bigEndian: true)
        put(1, at: 4, in: &data, bigEndian: true)
        put(MachOReader.cpuTypeArm64, at: 8, in: &data, bigEndian: true)
        put(1, at: 16, in: &data, bigEndian: true) // High half: offset is >4 GiB.
        put(64, at: 20, in: &data, bigEndian: true)
        data.replaceSubrange(64..<160, with: image())
        XCTAssertTrue(MachOReader.dylibs(in: data).isEmpty)
        put(0, at: 16, in: &data, bigEndian: true)
        XCTAssertEqual(MachOReader.dylibs(in: data), ["@rpath/Test.dylib"])
    }

    func testTruncatedInputsAndExtremeOffsetsDoNotReadOutOfBounds() {
        for size in 0..<32 {
            XCTAssertTrue(MachOReader.dylibs(in: Data(repeating: 0xff, count: size)).isEmpty)
        }
        XCTAssertNil(MachOReader.u32(Data(), at: Int.max, bigEndian: false))
    }
}
