import Foundation
import CryptoKit
import XCTest
@testable import NativeSigningLinkSmoke

/// Deferred synthetic consistency/transport fixtures, not platform signature,
/// chain/revocation, full Mach-O, installation or real app execution tests.
final class NativeSignedOutputTests: XCTestCase {
    private static let bundle = "com.example.fixture"
    private static let team = "ABCDE12345"
    private static let prefix = Data(repeating: 0xa5, count: 17_000)
    private static let special = [1: Data([1]), 2: Data([2]), 3: Data([3]), 5: Data([5]), 7: Data([7])]
    private static func put(_ value: Int, _ offset: Int, in bytes: inout Data) {
        for i in 0..<4 { bytes[offset + i] = UInt8(truncatingIfNeeded: value >> (24 - i * 8)) }
    }
    private static func directory() -> Data {
        let strings = Data(bundle.utf8) + Data([0]) + Data(team.utf8) + Data([0])
        let offset = 88 + strings.count + 224
        var bytes = Data(repeating: 0, count: offset + 64)
        for (position, value) in [(0, 0xfade0c02), (4, bytes.count), (8, 0x20400), (16, offset), (20, 88), (24, 7),
            (28, 2), (32, prefix.count), (48, 88 + bundle.utf8.count + 1), (76, prefix.count), (84, 1)] { put(value, position, in: &bytes) }
        bytes[36] = 32; bytes[37] = 2; bytes[39] = 14
        bytes.replaceSubrange(88..<(88 + strings.count), with: strings)
        for (slot, blob) in special {
            bytes.replaceSubrange((offset - slot * 32)..<(offset - (slot - 1) * 32), with: Data(SHA256.hash(data: blob)))
        }
        bytes.replaceSubrange(offset..<(offset + 32), with: Data(SHA256.hash(data: prefix.prefix(16384))))
        bytes.replaceSubrange((offset + 32)..<(offset + 64), with: Data(SHA256.hash(data: prefix.suffix(prefix.count - 16384))))
        return bytes
    }
    private static func verify(_ directory: Data, prefix: Data = NativeSignedOutputTests.prefix,
                               special: [Int: Data] = NativeSignedOutputTests.special) throws -> NativeCodeDirectoryEvidence {
        try NativeCodeDirectoryVerifier.verify(directory, executablePrefix: prefix, bundleIdentifier: bundle, teamIdentifier: team,
            textFileRange: 0..<prefix.count, specialSlotBlobs: special)
    }
    func testIndependentDirectoryVectorAndFinalPartialPage() throws {
        let receipt = try Self.verify(Self.directory())
        XCTAssertEqual(receipt.executablePrefixSHA256, NativeSigningIdentityOwner.hash(Self.prefix))
    }
    func testEveryPageAndSpecialBlobMutationRejects() throws {
        for offset in [0, 16383, 16384, Self.prefix.count - 1] {
            var changed = Self.prefix; changed[offset] ^= 1
            XCTAssertThrowsError(try Self.verify(Self.directory(), prefix: changed))
        }
        for slot in Self.special.keys {
            var special = Self.special; special[slot] = Data([255])
            XCTAssertThrowsError(try Self.verify(Self.directory(), special: special))
        }
    }
    func testUnsupportedPrivilegeFlagsAndHeaderMutationsReject() throws {
        for offset in [0, 4, 8, 12, 16, 20, 24, 28, 32, 36, 37, 38, 39, 40, 44, 48, 52, 56, 64, 72, 80] {
            var changed = Self.directory(); changed[offset] ^= 1
            XCTAssertThrowsError(try Self.verify(changed), "offset \(offset)")
        }
        var flags = Self.directory(); Self.put(0x11, 84, in: &flags)
        XCTAssertThrowsError(try Self.verify(flags)) // no ALLOW_UNSIGNED
    }
    func testTruncatedTrailingAndNonzeroAbsentSlotReject() throws {
        let directory = Self.directory()
        for size in [0, 1, 87, 88, directory.count - 1] { XCTAssertThrowsError(try Self.verify(Data(directory.prefix(size)))) }
        XCTAssertThrowsError(try Self.verify(directory + Data([0])))
        var changed = directory
        let hashOffset = directory.count - 64
        changed[hashOffset - 4 * 32] = 1
        XCTAssertThrowsError(try Self.verify(changed))
    }
    func testZIPIsDeterministicAndRoundTripsExecutableAndDirectory() throws {
        let entries = [NativeStoredZIPWriter.Entry(path: "Payload/Fixture.app/", bytes: Data()),
                       .init(path: "Payload/Fixture.app/Main", bytes: Data([1, 2, 3]), executable: true),
                       .init(path: "Payload/Fixture.app/Info.plist", bytes: Data([4, 5]))]
        let first = try NativeStoredZIPWriter.encode(entries)
        XCTAssertEqual(first, try NativeStoredZIPWriter.encode(Array(entries.reversed())))
        let index = try NativeIPAArchiveIndex.inspect(first)
        XCTAssertEqual(index.entries.count, 3)
        XCTAssertEqual(try NativeIPAEntryDecoder.decode(archive: first, entry: XCTUnwrap(index.entries.first { $0.path.hasSuffix("Main") })), Data([1, 2, 3]))
    }
    func testZIPUnsafeAndCollidingNamespacesReject() throws {
        for path in ["../outside", "/absolute", "a/../b", "a\\b", "A:stream", "a//b", "a./b", "a /b"] {
            XCTAssertThrowsError(try NativeStoredZIPWriter.encode([.init(path: path, bytes: Data([1]))]), path)
        }
        for paths in [["a", "A"], ["a", "a/b"], ["A/x", "a/y"]] {
            XCTAssertThrowsError(try NativeStoredZIPWriter.encode(paths.map { .init(path: $0, bytes: Data([1])) }))
        }
        XCTAssertThrowsError(try NativeStoredZIPWriter.encode([.init(path: "directory/", bytes: Data([1]))]))
        XCTAssertThrowsError(try NativeStoredZIPWriter.encode([]))
    }
}
