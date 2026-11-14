import XCTest
@testable import VexSign

final class ExecutablePreflightTests: XCTestCase {
    private func binary(commands: [UInt32], count: UInt32) -> Data {
        var words: [UInt32] = [0xfeedfacf, 0x0100000c, 0, 2, count, UInt32(commands.count * 4), 0, 0]
        words += commands
        var data = Data()
        for word in words { var value = word.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        return data
    }

    func testEncryptedIOSDeviceEvidence() throws {
        let data = binary(commands: [0x2c, 24, 0, 0, 1, 0, 0x32, 24, 2, 0x00120000, 0, 0], count: 2)
        let result = try XCTUnwrap(ExecutablePreflight.inspect(data))
        XCTAssertTrue(result.isArm64)
        XCTAssertTrue(result.encrypted)
        XCTAssertEqual(result.platform, 2)
        XCTAssertEqual(result.minimumOS, 0x00120000)
    }

    func testUnknownAndMalformedAreNotCompatibleEvidence() throws {
        XCTAssertNil(ExecutablePreflight.inspect(Data([0, 1, 2])))
        XCTAssertNil(ExecutablePreflight.inspect(binary(commands: [0x2c, 24, 0], count: 1)))
        XCTAssertNil(ExecutablePreflight.inspect(binary(commands: [0x32, 0], count: 1)))
        XCTAssertNil(ExecutablePreflight.inspect(binary(commands: [], count: 1)))
        let unknown = try XCTUnwrap(ExecutablePreflight.inspect(binary(commands: [], count: 0)))
        XCTAssertNil(unknown.platform)
    }

    private func fat(_ slices: [Data], sizes: [UInt32]? = nil, offsets: [UInt32]? = nil) -> Data {
        var result = Data()
        func append(_ word: UInt32) {
            var value = word.bigEndian
            withUnsafeBytes(of: &value) { result.append(contentsOf: $0) }
        }
        append(0xcafebabe); append(UInt32(slices.count))
        var offset = UInt32(8 + slices.count * 20)
        for (index, slice) in slices.enumerated() {
            append(0x0100000c); append(0); append(offsets?[index] ?? offset)
            append(sizes?[index] ?? UInt32(slice.count)); append(0)
            offset += UInt32(slice.count)
        }
        for slice in slices { result.append(slice) }
        return result
    }

    func testEveryFatSliceIsInspectedAndBounded() throws {
        let clean = binary(commands: [0x32, 24, 2, 0x00110000, 0, 0], count: 1)
        let encrypted = binary(commands: [0x2c, 24, 0, 0, 1, 0], count: 1)
        let evidence = try XCTUnwrap(ExecutablePreflight.inspectSlices(fat([clean, encrypted])))
        XCTAssertEqual(evidence.count, 2)
        XCTAssertFalse(evidence[0].encrypted)
        XCTAssertTrue(evidence[1].encrypted)
        // Its command table is inside the file, but outside its own declared slice.
        XCTAssertNil(ExecutablePreflight.inspectSlices(fat([clean, encrypted], sizes: [32, UInt32(encrypted.count)])))
        XCTAssertNil(ExecutablePreflight.inspectSlices(fat([clean, encrypted], offsets: [48, 48])))
        XCTAssertNil(ExecutablePreflight.inspectSlices(fat([clean], sizes: [UInt32.max])))
    }

    func testAllFATFormatsAndByteOrdersReturnEveryExactImageRange() throws {
        let image = try SigningRegressionFixture.machO(entitlements: ["flag": false])
        for wide in [false, true] { for big in [false, true] {
            let data = SigningRegressionFixture.fat([image, image], wide: wide, big: big)
            let images = try XCTUnwrap(ExecutablePreflight.inspectImages(data))
            XCTAssertEqual(images.count, 2)
            for slice in images {
                XCTAssertEqual(Data(data[slice.range]), image)
                XCTAssertEqual(slice.evidence.cpuType, 0x0100000c)
                XCTAssertEqual(slice.evidence.platform, 2)
                XCTAssertEqual(slice.evidence.fileType, 2)
            }
        } }
    }

    func testFATCPUAndSubtypeMustMatchEachImageAndReservedWordsMustBeZero() throws {
        let image = try SigningRegressionFixture.machO()
        for wide in [false, true] { for big in [false, true] {
            let valid = SigningRegressionFixture.fat([image], wide: wide, big: big)
            for (offset, value) in [(8, UInt32(12)), (12, 2), (wide ? 32 : 24, 31), (4, UInt32.max)] {
                var bytes = valid
                bytes.replaceSubrange(offset..<offset + 4, with: SigningRegressionFixture.u32(value, big: big))
                XCTAssertNil(ExecutablePreflight.inspectImages(bytes), "Invalid FAT metadata at \(offset)")
            }
            if wide {
                var bytes = valid
                bytes.replaceSubrange(36..<40, with: SigningRegressionFixture.u32(1, big: big))
                XCTAssertNil(ExecutablePreflight.inspectImages(bytes))
            }
        } }
    }

    func testBuildVersionToolCountCannotExceedCommand() {
        XCTAssertNil(ExecutablePreflight.inspect(binary(commands: [0x32, 24, 2, 0, 0, 1], count: 1)))
    }

    func testVersionBounds() {
        XCTAssertEqual(ExecutablePreflight.packedVersion("17.2.1"), 0x00110201)
        for text in ["17..1", "x", "65536.0", "17.256", "17.0.0.0", ""] {
            XCTAssertNil(ExecutablePreflight.packedVersion(text))
        }
    }
}
