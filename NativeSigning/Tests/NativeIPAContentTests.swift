import Foundation
import XCTest
@testable import NativeSigningLinkSmoke

/// Deferred synthetic byte fixtures, not real IPA/device/signing/trust validation.
final class NativeIPAContentTests: XCTestCase {
    private static let bundle = "com.example.fixture"
    private static func le(_ value: Int, count: Int = 4) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    private static func entry(_ data: Data, expanded: Int, crc: UInt32, method: Int = 8) -> NativeIPAArchiveIndex.Entry {
        .init(path: "fixture", isDirectory: false, method: method, crc32: crc, compressedRange: 0..<data.count, expandedCount: expanded)
    }
    private static func info(executable: String = "Fixture") throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": bundle, "CFBundleExecutable": executable,
            "CFBundlePackageType": "APPL", "CFBundleSupportedPlatforms": ["iPhoneOS"]], format: .xml, options: 0)
    }
    private static func executable() -> Data {
        let commands = le(0x19) + le(72) + Data(repeating: 0, count: 64)
        return le(0xfeedfacf) + le(0x0100000c) + le(0) + le(2) + le(1) + le(commands.count) + le(0) + le(0) + commands
    }
    private static func zip(_ files: [(String, Data)], badCRCPath: String? = nil) throws -> Data {
        var local = Data(); var central = Data()
        for (path, data) in files {
            let name = Data(path.utf8); let offset = local.count
            let crc: UInt32
            if path == badCRCPath { crc = 0 }
            else { crc = try NativeIPAEntryDecoder.crc32(data) }
            local += le(0x04034b50) + le(20, count: 2) + le(0, count: 2) + le(0, count: 2) + le(0, count: 2) + le(0, count: 2)
            local += le(Int(crc)) + le(data.count) + le(data.count) + le(name.count, count: 2) + le(0, count: 2) + name + data
            central += le(0x02014b50) + le(0x0314, count: 2) + le(20, count: 2) + le(0, count: 2) + le(0, count: 2) + le(0, count: 2) + le(0, count: 2)
            central += le(Int(crc)) + le(data.count) + le(data.count) + le(name.count, count: 2) + le(0, count: 2) + le(0, count: 2)
            central += le(0, count: 2) + le(0, count: 2) + le(0x81a40000) + le(offset) + name
        }
        return local + central + le(0x06054b50) + le(0, count: 2) + le(0, count: 2) + le(files.count, count: 2) + le(files.count, count: 2) + le(central.count) + le(local.count) + le(0, count: 2)
    }
    private static func files(extra: [(String, Data)] = []) throws -> [(String, Data)] {
        [("Payload/Main.app/Info.plist", try info()), ("Payload/Main.app/Fixture", executable())] + extra
    }
    func testCRCUsesIndependentStandardVectors() throws {
        XCTAssertEqual(try NativeIPAEntryDecoder.crc32(Data()), 0)
        XCTAssertEqual(try NativeIPAEntryDecoder.crc32(Data("123456789".utf8)), 0xcbf43926)
        XCTAssertEqual(try NativeIPAEntryDecoder.crc32(Data("abc".utf8)), 0x352441c2)
    }
    func testStoredCRCAndLengthMismatchReject() throws {
        let bytes = Data("abc".utf8)
        XCTAssertEqual(try NativeIPAEntryDecoder.decode(archive: bytes, entry: Self.entry(bytes, expanded: 3, crc: 0x352441c2, method: 0)), bytes)
        XCTAssertThrowsError(try NativeIPAEntryDecoder.decode(archive: bytes, entry: Self.entry(bytes, expanded: 3, crc: 0, method: 0)))
        XCTAssertThrowsError(try NativeIPAEntryDecoder.decode(archive: bytes, entry: Self.entry(bytes, expanded: 2, crc: 0x352441c2, method: 0)))
    }
    func testRawDeflateLiteralBlockAndEmptyStream() throws {
        let abc = Data([0x01,0x03,0,0xfc,0xff,0x61,0x62,0x63])
        XCTAssertEqual(try NativeIPAEntryDecoder.decode(archive: abc, entry: Self.entry(abc, expanded: 3, crc: 0x352441c2)), Data("abc".utf8))
        let empty = Data([0x01,0,0,0xff,0xff])
        XCTAssertEqual(try NativeIPAEntryDecoder.decode(archive: empty, entry: Self.entry(empty, expanded: 0, crc: 0)), Data())
    }
    func testRawDeflateTruncationTrailingInputAndOutputOverflowReject() {
        let valid = Data([0x01,0x03,0,0xfc,0xff,0x61,0x62,0x63])
        for bytes in [Data(valid.dropLast()), valid + Data([0xff]), valid + valid] {
            XCTAssertThrowsError(try NativeIPAEntryDecoder.decode(archive: bytes, entry: Self.entry(bytes, expanded: 3, crc: 0x352441c2)))
        }
        XCTAssertThrowsError(try NativeIPAEntryDecoder.decode(archive: valid, entry: Self.entry(valid, expanded: 2, crc: 0)))
    }
    func testFullSupportedContentScanRetainsEveryEntryHashAndExactMainBytes() throws {
        let files = try Self.files(extra: [("Payload/Main.app/Assets/image.dat", Data([1,2,3]))])
        let archive = try Self.zip(files)
        let content = try NativeIPAContentVerifier.verify(archive, bundleIdentifier: Self.bundle)
        XCTAssertEqual(content.archiveSHA256, NativeSigningIdentityOwner.hash(archive))
        XCTAssertEqual(content.entrySHA256.count, files.count)
        XCTAssertEqual(content.executable, Self.executable())
        XCTAssertEqual(content.infoPlist, files[0].1)
        XCTAssertEqual(content.expandedBytes, files.reduce(0) { $0 + $1.1.count })
        XCTAssertFalse(content.description.contains("Main.app"))
    }
    func testSlicedArchiveUsesRelativeEntryOffsets() throws {
        let archive = try Self.zip(Self.files())
        let prefixed = Data([0xff]) + archive
        let slice = prefixed.dropFirst()
        let content = try NativeIPAContentVerifier.verify(slice, bundleIdentifier: Self.bundle)
        XCTAssertEqual(content.archiveSHA256, NativeSigningIdentityOwner.hash(archive))
        XCTAssertEqual(content.executable, Self.executable())
    }
    func testCorruptResourceRejectsEvenWhenMainFilesAreValid() throws {
        let path = "Payload/Main.app/Assets/image.dat"
        let archive = try Self.zip(Self.files(extra: [(path, Data([1,2,3]))]), badCRCPath: path)
        XCTAssertThrowsError(try NativeIPAContentVerifier.verify(archive, bundleIdentifier: Self.bundle)) {
            XCTAssertEqual($0 as? NativeIPAEntryDecoder.Failure, .checksumMismatch)
        }
    }
    func testHiddenMachOFatAndStaticLibraryResourcesReject() throws {
        for data in [Self.executable(), Data([0xca,0xfe,0xba,0xbe]), Data("!<arch>\n".utf8)] {
            let archive = try Self.zip(Self.files(extra: [("Payload/Main.app/Assets/looks-like-image.png", data)]))
            XCTAssertThrowsError(try NativeIPAContentVerifier.verify(archive, bundleIdentifier: Self.bundle))
        }
    }
    func testInfoCannotSelectMissingOrDifferentMainExecutableOrBundle() throws {
        let missing = try Self.zip([("Payload/Main.app/Info.plist", Self.info(executable: "Missing")), ("Payload/Main.app/Fixture", Self.executable())])
        XCTAssertThrowsError(try NativeIPAContentVerifier.verify(missing, bundleIdentifier: Self.bundle))
        let valid = try Self.zip(Self.files())
        XCTAssertThrowsError(try NativeIPAContentVerifier.verify(valid, bundleIdentifier: "com.example.other"))
    }
    func testAlreadyCancelledInspectionNeverReturnsAReceipt() async throws {
        let bytes = try Self.zip(Self.files())
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await NativeIPAContentInspection.inspect(archive: bytes, bundleIdentifier: Self.bundle)
        }
        do { _ = try await task.value; XCTFail("Cancelled operation must not report success") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
    func testPublicReceiptExposesNoFilesAndSanitizesCorruptResources() async throws {
        let valid = try Self.zip(Self.files())
        let receipt = try await NativeIPAContentInspection.inspect(archive: valid, bundleIdentifier: Self.bundle)
        XCTAssertEqual(receipt.entryCount, 2)
        XCTAssertEqual(receipt.archiveSHA256, NativeSigningIdentityOwner.hash(valid))
        let bad = try Self.zip(Self.files(), badCRCPath: "Payload/Main.app/Fixture")
        do {
            _ = try await NativeIPAContentInspection.inspect(archive: bad, bundleIdentifier: Self.bundle)
            XCTFail("Checksums required")
        } catch { XCTAssertEqual(error as? NativeIPAInspectionError, .checksumMismatch) }
    }
}
