//
//  MachOInspectorTests.swift
//  VexSignTests
//
//  Synthetic binaries only: every fixture is built in memory, byte by byte. No real IPA, no
//  downloaded binary, nothing a licence could apply to. The point is the bounds checks, so
//  most of these tests deliberately corrupt one field of an otherwise valid image.
//

import Foundation
import XCTest
@testable import VexSign

final class MachOInspectorTests: XCTestCase {
    // MARK: - Fixtures

    private let arm64: UInt32 = 0x0100_000c
    private let x86_64: UInt32 = 0x0100_0007
    private let armv7: UInt32 = 12

    private func put(_ value: UInt32, at offset: Int, in data: inout Data, bigEndian: Bool = false) {
        let bytes = (0..<4).map { UInt8(truncatingIfNeeded: value >> UInt32((bigEndian ? 3 - $0 : $0) * 8)) }
        data.replaceSubrange(offset..<(offset + 4), with: bytes)
    }

    private func padded(_ bytes: [UInt8]) -> [UInt8] {
        var result = bytes
        while result.count % 4 != 0 { result.append(0) }
        return result
    }

    /// `LC_LOAD_DYLIB` (and its lazy/weak/reexport siblings), fixed part 24 bytes.
    private func dylib(_ path: String, command: UInt32 = 0x0c) -> [UInt8] {
        let name = padded(Array(path.utf8) + [0])
        var bytes: [UInt8] = []
        bytes += littleEndian(command)
        bytes += littleEndian(UInt32(24 + name.count))
        bytes += littleEndian(UInt32(24)) // name offset
        bytes += littleEndian(UInt32(2))  // timestamp
        bytes += littleEndian(UInt32(0))  // current version
        bytes += littleEndian(UInt32(0x10000)) // compatibility version
        bytes += name
        return bytes
    }

    /// `LC_RPATH`, fixed part 12 bytes.
    private func rpath(_ path: String) -> [UInt8] {
        let name = padded(Array(path.utf8) + [0])
        var bytes: [UInt8] = []
        bytes += littleEndian(0x8000_001c)
        bytes += littleEndian(UInt32(12 + name.count))
        bytes += littleEndian(UInt32(12))
        bytes += name
        return bytes
    }

    private func buildVersion(platform: UInt32 = 2, minimum: UInt32 = 0x000f_0000, sdk: UInt32 = 0x0011_0000) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes += littleEndian(0x32)
        bytes += littleEndian(UInt32(24))
        bytes += littleEndian(platform)
        bytes += littleEndian(minimum)
        bytes += littleEndian(sdk)
        bytes += littleEndian(UInt32(0)) // ntools
        return bytes
    }

    private func versionMinIPhoneOS(_ minimum: UInt32, sdk: UInt32) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes += littleEndian(0x25)
        bytes += littleEndian(UInt32(16))
        bytes += littleEndian(minimum)
        bytes += littleEndian(sdk)
        return bytes
    }

    private func codeSignature() -> [UInt8] {
        littleEndian(0x1d) + littleEndian(UInt32(16)) + littleEndian(UInt32(0)) + littleEndian(UInt32(0))
    }

    private func encryptionInfo64(cryptID: UInt32) -> [UInt8] {
        littleEndian(0x2c) + littleEndian(UInt32(24)) + littleEndian(UInt32(0))
            + littleEndian(UInt32(0)) + littleEndian(cryptID) + littleEndian(UInt32(0))
    }

    private func littleEndian(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: value >> UInt32($0 * 8)) }
    }

    /// A thin 64-bit image whose declared command bytes may disagree with what follows.
    private func thin(
        cpu: UInt32? = nil,
        subtype: UInt32 = 0,
        commands: [[UInt8]],
        declaredCount: UInt32? = nil,
        declaredBytes: UInt32? = nil,
        trailingBytes: Int = 0
    ) -> Data {
        let body = commands.flatMap { $0 }
        var data = Data(repeating: 0, count: 32)
        put(0xfeedfacf, at: 0, in: &data)
        put(cpu ?? arm64, at: 4, in: &data)
        put(subtype, at: 8, in: &data)
        put(6, at: 12, in: &data) // MH_EXECUTE
        put(declaredCount ?? UInt32(commands.count), at: 16, in: &data)
        put(declaredBytes ?? UInt32(body.count), at: 20, in: &data)
        data.append(contentsOf: body)
        data.append(contentsOf: [UInt8](repeating: 0, count: trailingBytes))
        return data
    }

    /// A universal container over already-built thin slices.
    private func fat(_ slices: [(cpu: UInt32, image: Data)], declared: UInt32? = nil, entrySize: Int = 20) -> Data {
        let count = declared ?? UInt32(slices.count)
        var header = Data(repeating: 0, count: 8 + entrySize * slices.count)
        put(0xcafebabe, at: 0, in: &header, bigEndian: true)
        put(count, at: 4, in: &header, bigEndian: true)
        var offset = header.count
        for (index, slice) in slices.enumerated() {
            let entry = 8 + index * entrySize
            put(slice.cpu, at: entry, in: &header, bigEndian: true)
            put(0, at: entry + 4, in: &header, bigEndian: true)
            put(UInt32(offset), at: entry + 8, in: &header, bigEndian: true)
            put(UInt32(slice.image.count), at: entry + 12, in: &header, bigEndian: true)
            put(0, at: entry + 16, in: &header, bigEndian: true)
            offset += slice.image.count
        }
        var data = header
        for slice in slices { data.append(slice.image) }
        return data
    }

    private func signedImage(extra: [[UInt8]] = []) -> Data {
        thin(commands: [
            dylib("@rpath/First.dylib"),
            dylib("@rpath/Second.dylib"),
            dylib("@rpath/First.dylib"), // duplicate on purpose
            rpath("@executable_path/Frameworks"),
            buildVersion(),
            codeSignature()
        ] + extra)
    }

    // MARK: - Thin binaries

    func testThinArm64BinaryReportsItsShape() {
        let inspection = MachOInspector.inspect(signedImage())
        XCTAssertEqual(inspection.slices.count, 1)
        let slice = inspection.slices.first
        XCTAssertEqual(slice?.architecture, .arm64)
        XCTAssertEqual(slice?.is64Bit, true)
        XCTAssertEqual(slice?.platform, "iOS")
        XCTAssertEqual(slice?.minimumSystemVersion, "15.0")
        XCTAssertEqual(slice?.sdkVersion, "17.0")
        XCTAssertTrue(slice?.hasCodeSignature == true)
        XCTAssertEqual(inspection.issues, [])
        XCTAssertFalse(inspection.isUniversal)
        XCTAssertTrue(inspection.architectures == [.arm64])
    }

    func testDuplicateLoadsAreDeduplicatedInArchiveOrder() {
        XCTAssertEqual(MachOInspector.inspect(signedImage()).resolvedLinkedLibraries,
                       ["@rpath/First.dylib", "@rpath/Second.dylib"])
    }

    func testWeakLoadsAreReportedSeparatelyFromStrongOnes() {
        let image = thin(commands: [dylib("@rpath/Weak.dylib", command: 0x8000_0018), codeSignature()])
        let slice = MachOInspector.inspect(image).slices.first
        XCTAssertEqual(slice?.weakInstallNames, ["@rpath/Weak.dylib"])
        XCTAssertEqual(slice?.installNames, [])
        XCTAssertEqual(slice?.linkedLibraries, ["@rpath/Weak.dylib"])
    }

    func testRuntimeSearchPathsAreReported() {
        XCTAssertEqual(MachOInspector.inspect(signedImage()).slices.first?.runtimeSearchPaths,
                       ["@executable_path/Frameworks"])
    }

    func testUnsignedBinaryIsReportedRatherThanTreatedAsInvalid() {
        let inspection = MachOInspector.inspect(thin(commands: [dylib("@rpath/A.dylib")]))
        XCTAssertEqual(inspection.slices.count, 1)
        XCTAssertEqual(inspection.issues, [.missingCodeSignature("arm64")])
    }

    func testEncryptedSlotIsReportedWithItsCryptID() {
        let inspection = MachOInspector.inspect(thin(commands: [encryptionInfo64(cryptID: 1), codeSignature()]))
        XCTAssertTrue(inspection.isEncrypted)
        XCTAssertEqual(inspection.slices.first?.encryptionID, 1)
        XCTAssertEqual(inspection.issues, [.encryptedBinary("arm64", encryptionID: 1)])
    }

    func testUnencryptedSlotWithZeroCryptIDIsNotReportedAsEncrypted() {
        let inspection = MachOInspector.inspect(thin(commands: [encryptionInfo64(cryptID: 0), codeSignature()]))
        XCTAssertFalse(inspection.isEncrypted)
        XCTAssertNil(inspection.slices.first?.encryptionID)
    }

    func testSimulatorSliceIsUnsupportedAndHasNoDeviceNativeSlice() {
        let inspection = MachOInspector.inspect(thin(cpu: x86_64, commands: [codeSignature()]))
        XCTAssertEqual(inspection.slices.first?.architecture, .x86_64)
        XCTAssertTrue(inspection.deviceNativeSlices.isEmpty)
        XCTAssertEqual(inspection.issues, [.unsupportedArchitecture("x86_64")])
        XCTAssertEqual(MachOInspector.deviceNativeCompatibility(inspection), .noDeviceNativeSlice)
    }

    func testLegacy32BitImageIsParsedWithTheSmallerHeader() {
        var data = Data(repeating: 0, count: 28)
        put(0xfeedface, at: 0, in: &data)
        put(armv7, at: 4, in: &data)
        put(6, at: 12, in: &data)
        put(0, at: 16, in: &data)
        put(0, at: 20, in: &data)
        let inspection = MachOInspector.inspect(data)
        XCTAssertEqual(inspection.slices.first?.architecture, .armv7)
        XCTAssertEqual(inspection.slices.first?.is64Bit, false)
        XCTAssertEqual(inspection.issues, [.missingCodeSignature("armv7")])
    }

    func testVersionMinCommandSuppliesSystemAndPlatform() {
        let inspection = MachOInspector.inspect(thin(commands: [
            versionMinIPhoneOS(0x000c_0300, sdk: 0x000d_0000), codeSignature()
        ]))
        XCTAssertEqual(inspection.slices.first?.platform, "iOS")
        XCTAssertEqual(inspection.slices.first?.minimumSystemVersion, "12.3")
        XCTAssertEqual(inspection.slices.first?.sdkVersion, "13.0")
    }

    // MARK: - Universal binaries

    func testUniversalBinaryKeepsEverySliceDistinct() {
        let inspection = MachOInspector.inspect(fat([
            (arm64, signedImage()),
            (x86_64, thin(cpu: x86_64, commands: [codeSignature()]))
        ]))
        XCTAssertTrue(inspection.isUniversal)
        XCTAssertEqual(inspection.architectures, [.arm64, .x86_64])
        XCTAssertEqual(inspection.deviceNativeSlices.count, 1)
        // Only the simulator slice is unusual; it is reported, the arm64 slice is not.
        XCTAssertEqual(inspection.issues, [.unsupportedArchitecture("x86_64")])
    }

    func testUniversalWithoutADeviceSliceSaysSo() {
        let inspection = MachOInspector.inspect(fat([(x86_64, thin(cpu: x86_64, commands: [codeSignature()]))]))
        XCTAssertEqual(MachOInspector.deviceNativeCompatibility(inspection), .noDeviceNativeSlice)
    }

    func testFatHeaderListingMoreSlicesThanPresentIsTruncated() {
        let inspection = MachOInspector.inspect(fat([(arm64, signedImage())], declared: 3))
        XCTAssertTrue(inspection.issues.contains(.truncatedFatHeader))
    }

    func testOverlappingSliceRangesAreRejected() {
        var data = fat([(arm64, signedImage()), (x86_64, thin(cpu: x86_64, commands: [codeSignature()]))])
        // Point the second entry at the first entry's bytes.
        put(UInt32(8 + 2 * 20), at: 8 + 20 + 8, in: &data, bigEndian: true)
        XCTAssertTrue(MachOInspector.inspect(data).issues.contains(.truncatedFatHeader))
    }

    func testFat64StoresSliceOffsetsWithoutTruncatingTheHighHalf() {
        var data = Data(repeating: 0, count: 8 + 32 + 64)
        put(0xcafebabf, at: 0, in: &data, bigEndian: true)
        put(1, at: 4, in: &data, bigEndian: true)
        put(arm64, at: 8, in: &data, bigEndian: true)
        put(1, at: 16, in: &data, bigEndian: true) // offset > 4 GiB
        put(64, at: 24, in: &data, bigEndian: true)
        XCTAssertTrue(MachOInspector.inspect(data).issues.contains(.truncatedFatHeader))
    }

    // MARK: - Malformed input

    func testEmptyAndTinyInputIsNotABinary() {
        XCTAssertEqual(MachOInspector.inspect(Data()), .empty)
        XCTAssertEqual(MachOInspector.inspect(Data([0xcf, 0xfa])).issues, [.notMachO])
        for size in 0..<32 {
            let junk = Data(repeating: 0xcf, count: size)
            XCTAssertFalse(MachOInspector.inspect(junk).issues.isEmpty)
        }
    }

    func testCommandLengthSmallerThanItsHeaderIsMalformed() {
        var commands = dylib("@rpath/A.dylib")
        commands[4] = 6 // cmdsize low byte
        commands[5] = 0
        commands[6] = 0
        commands[7] = 0
        let inspection = MachOInspector.inspect(thin(commands: [commands, codeSignature()]))
        XCTAssertEqual(inspection.issues.first, .malformedLoadCommands(commandIndex: 0))
        XCTAssertEqual(inspection.slices.count, 1)
        XCTAssertEqual(inspection.resolvedLinkedLibraries, [])
    }

    func testCommandLengthPastTheRegionIsMalformed() {
        let inspection = MachOInspector.inspect(thin(commands: [dylib("@rpath/A.dylib")], declaredBytes: 16))
        XCTAssertTrue(inspection.issues.contains(.malformedLoadCommands(commandIndex: 0)))
    }

    func testDeclaredCommandCountBeyondDeclaredBytesIsTruncated() {
        let inspection = MachOInspector.inspect(thin(commands: [codeSignature()], declaredCount: 8))
        XCTAssertEqual(inspection.issues, [.truncatedHeader])
        XCTAssertTrue(inspection.slices.isEmpty)
    }

    func testDeclaredBytesBeyondTheFileIsTruncated() {
        let inspection = MachOInspector.inspect(thin(commands: [codeSignature()], declaredBytes: 4096))
        XCTAssertEqual(inspection.issues, [.truncatedHeader])
    }

    func testNameOffsetInsideTheCommandHeaderIsRejected() {
        var commands = dylib("@rpath/A.dylib")
        commands[8] = 8 // name offset < 24
        commands[9] = 0
        commands[10] = 0
        commands[11] = 0
        let inspection = MachOInspector.inspect(thin(commands: [commands, codeSignature()]))
        XCTAssertEqual(inspection.issues.first, .invalidStringOffset(commandIndex: 0))
        XCTAssertEqual(inspection.resolvedLinkedLibraries, [])
    }

    func testNameOffsetPastTheCommandIsRejected() {
        var commands = dylib("@rpath/A.dylib")
        commands[8] = 0xff // name offset far past the command end
        commands[9] = 0
        commands[10] = 0
        commands[11] = 0
        let inspection = MachOInspector.inspect(thin(commands: [commands, codeSignature()]))
        XCTAssertEqual(inspection.issues.first, .invalidStringOffset(commandIndex: 0))
    }

    func testUnterminatedNameIsRejected() {
        // 15 characters, so the name plus its terminator fills the command exactly and the
        // missing terminator cannot be satisfied by alignment padding.
        let path = "@rpath/Ab.dylib"
        var commands = dylib(path)
        XCTAssertEqual(commands.count, 24 + 16)
        // Overwrite the terminating NUL with a printable byte: no string, no name.
        commands[24 + path.utf8.count] = 0x41
        let inspection = MachOInspector.inspect(thin(commands: [commands, codeSignature()]))
        XCTAssertEqual(inspection.resolvedLinkedLibraries, [])
        XCTAssertEqual(inspection.issues.first, .invalidStringOffset(commandIndex: 0))
    }

    func testTruncatedHeaderIsReportedNotCrashed() {
        let image = signedImage()
        for length in 0..<32 {
            let truncated = image.prefix(length)
            XCTAssertFalse(MachOInspector.inspect(Data(truncated)).slices.count > 0)
        }
    }

    func testArbitraryBytesNeverTrap() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<50 {
            let count = Int.random(in: 0..<256, using: &generator)
            let data = Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) })
            _ = MachOInspector.inspect(data)
        }
    }

    // MARK: - Pure helpers

    func testPackedVersionFormatting() {
        XCTAssertEqual(MachOInspector.versionString(0x000f_0000), "15.0")
        XCTAssertEqual(MachOInspector.versionString(0x0010_0401), "16.4.1")
        XCTAssertEqual(MachOInspector.versionString(0), "0.0")
    }

    func testPlatformNamesCoverTheCommandsIosBinariesUse() {
        XCTAssertEqual(MachOInspector.platformName(2), "iOS")
        XCTAssertEqual(MachOInspector.platformName(7), "iOS Simulator")
        XCTAssertEqual(MachOInspector.platformName(1), "macOS")
    }

    func testInspectionIsDeterministic() {
        let data = fat([(arm64, signedImage()), (x86_64, thin(cpu: x86_64, commands: [codeSignature()]))])
        XCTAssertEqual(MachOInspector.inspect(data), MachOInspector.inspect(data))
    }
}
