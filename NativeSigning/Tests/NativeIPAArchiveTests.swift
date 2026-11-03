import Foundation
import XCTest
@testable import NativeSigningLinkSmoke

/// ZIP record/namespace fixtures only. Deliberately zero CRC metadata is not a
/// checksum proof: index/layout acceptance must never become signing authority.
final class NativeIPAArchiveTests: XCTestCase {
    private struct Item {
        let name: String
        var body = Data("unverified".utf8)
        var localName: String?
        var flags = 0
        var method = 0
        var expanded: Int?
        var extra = Data()
        var symlink = false
    }
    private static func le(_ value: Int, _ count: Int = 4) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    private static func zip(_ items: [Item], prefix: Data = Data(), descriptorSignature: Bool = true) -> Data {
        var local = prefix; var central = Data()
        for item in items {
            let offset = local.count; let name = Data(item.name.utf8)
            let localName = Data((item.localName ?? item.name).utf8)
            let directory = item.name.hasSuffix("/")
            let body = directory ? Data() : item.body
            let expanded = item.expanded ?? body.count
            let descriptor = item.flags & 8 != 0
            local += le(0x04034b50) + le(20, 2) + le(item.flags, 2) + le(item.method, 2) + le(0, 2) + le(0, 2)
            local += le(0) + le(descriptor ? 0 : body.count) + le(descriptor ? 0 : expanded)
            local += le(localName.count, 2) + le(item.extra.count, 2) + localName + item.extra + body
            if descriptor { local += (descriptorSignature ? le(0x08074b50) : Data()) + le(0) + le(body.count) + le(expanded) }
            let mode = item.symlink ? 0xa1ff : (directory ? 0x41ed : 0x81a4)
            central += le(0x02014b50) + le(0x0314, 2) + le(20, 2) + le(item.flags, 2) + le(item.method, 2) + le(0, 2) + le(0, 2)
            central += le(0) + le(body.count) + le(expanded) + le(name.count, 2) + le(item.extra.count, 2) + le(0, 2)
            central += le(0, 2) + le(0, 2) + le(mode << 16 | (directory ? 0x10 : 0)) + le(offset) + name + item.extra
        }
        return local + central + le(0x06054b50) + le(0, 2) + le(0, 2) + le(items.count, 2) + le(items.count, 2) + le(central.count) + le(local.count) + le(0, 2)
    }
    private static func inspect(_ names: [String]) throws -> NativeIPAArchiveIndex {
        try .inspect(zip(names.map { Item(name: $0) }))
    }
    func testInventoryBindsArchiveAndExactPayloadRangesWithoutClaimingCRC() throws {
        let bytes = Self.zip([Item(name: "Payload/Main.app/Info.plist")])
        let index = try NativeIPAArchiveIndex.inspect(bytes)
        XCTAssertEqual(index.archiveSHA256, NativeSigningIdentityOwner.hash(bytes))
        XCTAssertEqual(index.entries.count, 1)
        XCTAssertEqual(bytes.subdata(in: index.entries[0].compressedRange), Data("unverified".utf8))
        XCTAssertEqual(index.entries[0].crc32, 0) // not the checksum of these bytes
        XCTAssertEqual(index.description, "NativeIPAArchiveIndex(redacted; content unverified)")
    }
    func testSignedAndUnsignedDataDescriptorsAreBoundToCentralSizes() throws {
        var item = Item(name: "Payload/Main.app/Info.plist"); item.flags = 8
        for signature in [true, false] {
            XCTAssertEqual(try NativeIPAArchiveIndex.inspect(Self.zip([item], descriptorSignature: signature)).entries.count, 1)
        }
        var bad = Self.zip([item]); let descriptorSizeOffset = 30 + item.name.utf8.count + item.body.count + 8
        bad[descriptorSizeOffset] ^= 1
        XCTAssertThrowsError(try NativeIPAArchiveIndex.inspect(bad))
    }
    func testTraversalAbsoluteBackslashColonControlAndNonASCIIPathsReject() {
        for name in ["../Payload/Main.app/Info.plist", "/Payload/Main.app/Info.plist", "Payload//Main.app/Info.plist", "Payload/Main.app/../Info.plist", "Payload\\Main.app\\Info.plist", "Payload/Main.app/C:bad", "Payload/Main.app/bad\u{0}", "Payload/Main.app/café", "Payload/Main.app/bad.", "Payload/Main.app/bad "] {
            XCTAssertThrowsError(try Self.inspect([name]))
        }
    }
    func testCaseAliasesDuplicatesAndFileDirectoryConflictsRejectInEitherOrder() {
        let cases = [["Payload/Main.app/Info.plist", "Payload/Main.app/Info.plist"],
            ["Payload/Main.app/Info.plist", "Payload/main.app/Fixture"],
            ["Payload/Main.app/Asset/A", "Payload/Main.app/asset/B"],
            ["Payload/Main.app/File", "Payload/Main.app/File/Child"]]
        for names in cases {
            XCTAssertThrowsError(try Self.inspect(names))
            XCTAssertThrowsError(try Self.inspect(Array(names.reversed())))
        }
    }
    func testSymlinksEncryptionZIP64AndAlternateUnicodeExtrasReject() {
        var symlink = Item(name: "Payload/Main.app/Link"); symlink.symlink = true
        var encrypted = Item(name: "Payload/Main.app/Info.plist"); encrypted.flags = 1
        var zip64 = Item(name: "Payload/Main.app/Info.plist"); zip64.extra = Self.le(1, 2) + Self.le(0, 2)
        var unicode = Item(name: "Payload/Main.app/Info.plist"); unicode.extra = Self.le(0x7075, 2) + Self.le(0, 2)
        for item in [symlink, encrypted, zip64, unicode] { XCTAssertThrowsError(try NativeIPAArchiveIndex.inspect(Self.zip([item]))) }
    }
    func testCentralAndLocalFilenameMismatchAndPrependedRecordsReject() {
        var item = Item(name: "Payload/Main.app/Info.plist"); item.localName = "Payload/Main.app/Evil.plist"
        XCTAssertThrowsError(try NativeIPAArchiveIndex.inspect(Self.zip([item])))
        XCTAssertThrowsError(try NativeIPAArchiveIndex.inspect(Self.zip([Item(name: "Payload/Main.app/Info.plist")], prefix: Data([0,0,0,0]))))
    }
    func testDeclaredExpansionLimitsAndTruncatedEOCDReject() {
        var item = Item(name: "Payload/Main.app/Info.plist"); item.body = Data([1]); item.method = 8; item.expanded = 251
        XCTAssertThrowsError(try NativeIPAArchiveIndex.inspect(Self.zip([item])))
        XCTAssertThrowsError(try NativeIPAArchiveIndex.inspect(Data(Self.zip([Item(name: "Payload/Main.app/Info.plist")]).dropLast())))
    }
    func testSingleMainAppLayoutAllowsImplicitAndExplicitParentDirectories() throws {
        for names in [["Payload/Main.app/Info.plist", "Payload/Main.app/Fixture", "Payload/Main.app/Assets/image.png"],
                      ["Payload/", "Payload/Main.app/", "Payload/Main.app/Info.plist", "Payload/Main.app/Fixture"]] {
            let layout = try NativeIPAArchiveLayout.singleMainApp(Self.inspect(names))
            XCTAssertEqual(layout.appRoot, "Payload/Main.app")
            XCTAssertEqual(layout.infoEntry.path, "Payload/Main.app/Info.plist")
            XCTAssertFalse(layout.description.contains("Main.app"))
        }
    }
    func testMultipleRootsOutsidePayloadAndNestedExecutableLayoutsReject() {
        for name in ["Other.app/Info.plist", "Payload/Other.app/Info.plist", "iTunesMetadata.plist", "Payload/Main.app/PlugIns/Widget.appex/Info.plist",
                     "Payload/Main.app/Frameworks/Library.framework/Library", "Payload/Main.app/Watch/Watch.app/Info.plist", "Payload/Main.app/libHidden.dylib"] {
            XCTAssertThrowsError(try NativeIPAArchiveLayout.singleMainApp(Self.inspect(["Payload/Main.app/Info.plist", name])))
        }
        XCTAssertThrowsError(try NativeIPAArchiveLayout.singleMainApp(Self.inspect(["Payload/Main.app/Fixture"])))
    }
}
