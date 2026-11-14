import Foundation
import XCTest
@testable import NativeSigningLinkSmoke

/// Deferred synthetic layouts only, not executable instructions or dyld/device
/// acceptance. No code is run, signed, installed or given trust by these vectors.
final class NativeMachOMutationTests: XCTestCase {
    private static func put(_ value: UInt64, _ p: Int, _ n: Int = 4, in data: inout Data) {
        for i in 0..<n { data[p + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
    }
    private static func string(_ value: String, _ p: Int, in data: inout Data) {
        let bytes = Data(value.utf8); data.replaceSubrange(p..<(p + bytes.count), with: bytes)
    }
    static func image(signatureSize: Int = 32, linkeditVMSize: Int = 4096) -> Data {
        var data = Data(repeating: 0, count: 8192 + signatureSize)
        put(0xfeedfacf, 0, in: &data); put(0x0100000c, 4, in: &data); put(2, 12, in: &data)
        put(4, 16, in: &data); put(264, 20, in: &data)
        // __TEXT, one __text section containing the LC_MAIN entry.
        let text = 32
        put(0x19, text, in: &data); put(152, text + 4, in: &data); string("__TEXT", text + 8, in: &data)
        put(0x100000000, text + 24, 8, in: &data); put(4096, text + 32, 8, in: &data)
        put(4096, text + 48, 8, in: &data); put(5, text + 56, in: &data); put(5, text + 60, in: &data); put(1, text + 64, in: &data)
        let section = text + 72
        string("__text", section, in: &data); string("__TEXT", section + 16, in: &data)
        put(0x100000200, section + 32, 8, in: &data); put(512, section + 40, 8, in: &data)
        put(512, section + 48, in: &data); put(2, section + 52, in: &data); put(0x80000400, section + 64, in: &data)
        let linkedit = 184
        put(0x19, linkedit, in: &data); put(72, linkedit + 4, in: &data); string("__LINKEDIT", linkedit + 8, in: &data)
        put(0x100001000, linkedit + 24, 8, in: &data); put(UInt64(linkeditVMSize), linkedit + 32, 8, in: &data)
        put(4096, linkedit + 40, 8, in: &data); put(UInt64(4096 + signatureSize), linkedit + 48, 8, in: &data)
        // VM allocation rounds to pages and must contain the entire file image.
        put(UInt64(max(linkeditVMSize, 8192)), linkedit + 32, 8, in: &data)
        put(1, linkedit + 56, in: &data); put(1, linkedit + 60, in: &data)
        put(0x80000028, 256, in: &data); put(24, 260, in: &data); put(512, 264, 8, in: &data)
        put(0x1d, 280, in: &data); put(16, 284, in: &data); put(8192, 288, in: &data); put(UInt64(signatureSize), 292, in: &data)
        return data
    }
    func testExistingSignatureReplacementAndLinkeditGrowth() throws {
        let original = Self.image(); var output = Self.image(signatureSize: 64, linkeditVMSize: 12288)
        output[8192] = 42
        let evidence = try NativeMachOMutationVerifier.verify(original: original, output: output)
        XCTAssertEqual(evidence.textFileRange, 0..<4096)
        XCTAssertEqual(evidence.signatureRange, 8192..<8256)
        XCTAssertEqual(evidence.outputSHA256, NativeSigningIdentityOwner.hash(output))
    }
    func testInstructionsHeaderAndOtherLoadCommandsCannotMutate() throws {
        let original = Self.image()
        for p in [4, 24, 32 + 24, 32 + 60, 32 + 72 + 64, 184 + 24, 184 + 40, 264, 512, 4095, 4096, 8191] {
            var changed = original; changed[p] ^= 1
            XCTAssertThrowsError(try NativeMachOMutationVerifier.verify(original: original, output: changed), "byte \(p)")
        }
    }
    func testEntryMustBeAlignedInsideInstructionSection() throws {
        for entry in [UInt64(0), 128, 513, 1024, 4096, UInt64.max] {
            var data = Self.image(); Self.put(entry, 264, 8, in: &data)
            XCTAssertThrowsError(try NativeMachOSigningLayout.inspect(data))
        }
        var noInstructions = Self.image(); Self.put(0, 32 + 72 + 64, in: &noInstructions)
        XCTAssertThrowsError(try NativeMachOSigningLayout.inspect(noInstructions))
    }
    func testOverlapOverflowProtectionAndSectionBoundsReject() throws {
        let cases: [(Int, UInt64, Int)] = [
            (184 + 24, 0x100000000, 8), (184 + 40, 0, 8), (32 + 32, UInt64.max, 8),
            (24, 0x20000, 4), (24, 0x100, 4), (32 + 56, 7, 4), (32 + 72 + 32, 0x100001000, 8), (32 + 72 + 40, UInt64.max, 8),
            (32 + 72 + 48, 4095, 4), (32 + 72 + 52, 63, 4), (32 + 72 + 60, 1, 4)
        ]
        for (offset, value, width) in cases {
            var data = Self.image(); Self.put(value, offset, width, in: &data)
            XCTAssertThrowsError(try NativeMachOSigningLayout.inspect(data))
        }
    }
    func testMovedNonterminalOrMissingSignatureAllocationRejects() throws {
        let original = Self.image()
        let cases: [(Int, UInt64)] = [(280, 0x31), (288, 8184), (288, 0), (292, 0), (292, 31)]
        for (offset, value) in cases {
            var data = original; Self.put(value, offset, in: &data)
            XCTAssertThrowsError(try NativeMachOSigningLayout.inspect(data))
        }
        XCTAssertThrowsError(try NativeMachOSigningLayout.inspect(original + Data([0])))
        XCTAssertThrowsError(try NativeMachOSigningLayout.inspect(Data(original.prefix(31))))
    }
}
