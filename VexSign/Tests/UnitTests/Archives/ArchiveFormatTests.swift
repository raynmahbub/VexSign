//
//  ArchiveFormatTests.swift
//  VexSignTests
//
//  The `.deb` member list and the compression detector used to be two hand-maintained lists of
//  one fact. These tests are what keeps them one: a member the selector accepts must resolve to a
//  format the detector decodes, and every format must be reachable by magic.
//

import XCTest
@testable import VexSign

final class ArchiveFormatTests: XCTestCase {
    // MARK: - Detection

    func testEveryFormatWithAMagicIsDetectedByItsMagicAlone() throws {
        for format in ArchiveFormat.allCases {
            guard let magic = format.magicPrefix else { continue }
            let data = Data(magic + [0x00, 0x01, 0x02, 0x03])
            XCTAssertEqual(
                ArchiveFormat.detect(data, extensionHint: ""),
                format,
                "\(format) must be recognised without trusting a file name"
            )
        }
    }

    func testAMislabelledPayloadIsDetectedByItsMagicNotItsName() {
        // The case that started this: a `data.tar.lzma` that is actually XZ.
        let xz = Data([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00, 0x00, 0x04])
        XCTAssertEqual(ArchiveFormat.detect(xz, extensionHint: "lzma"), .xz)
    }

    func testTheFormatWithoutAMagicIsRecognisedByItsExtension() {
        XCTAssertNil(ArchiveFormat.lzma.magicPrefix)
        XCTAssertEqual(ArchiveFormat.detect(Data([0x5D, 0x00, 0x00]), extensionHint: "lzma"), .lzma)
        XCTAssertNil(ArchiveFormat.detect(Data([0x5D, 0x00, 0x00]), extensionHint: ""))
    }

    func testUnknownContentAndExtensionResolveToNoFormat() {
        XCTAssertNil(ArchiveFormat.detect(Data("not an archive".utf8), extensionHint: "rar"))
        XCTAssertNil(ArchiveFormat.detect(Data(), extensionHint: ""))
    }

    // MARK: - Debian members

    func testEveryAcceptedDebianMemberResolvesToAFormatTheDetectorDecodes() throws {
        for member in ArchiveFormat.debianDataMembers where member != "data.tar" {
            let format = try XCTUnwrap(
                ArchiveFormat.debianMember(member),
                "\(member) is accepted by the selector but maps to no format"
            )
            XCTAssertTrue(
                ArchiveFormat.allCases.contains(format),
                "\(format) is not a format this build decodes"
            )
            XCTAssertEqual(
                ArchiveFormat.detect(Data(), extensionHint: String(member.dropFirst("data.tar.".count))),
                format
            )
        }
    }

    func testAnUncompressedMemberHasNoFormatAndNotEverySuffixIsAccepted() {
        XCTAssertNil(ArchiveFormat.debianMember("data.tar"))
        XCTAssertNil(ArchiveFormat.debianMember("data.tar.lz4"))
        XCTAssertNil(ArchiveFormat.debianMember("control.tar.gz"))
        XCTAssertFalse(ArchiveFormat.debianDataMembers.contains("data.tar.lz4"))
    }

    func testZstdIsAcceptedAsBothAMemberAndAStandaloneArchive() {
        XCTAssertTrue(ArchiveFormat.debianDataMembers.contains("data.tar.zst"))
        XCTAssertEqual(ArchiveFormat.debianMember("data.tar.zst"), .zstd)
        XCTAssertEqual(ArchiveFormat.detect(Data([0x28, 0xB5, 0x2F, 0xFD]), extensionHint: ""), .zstd)
    }

    /// The refusal sentence is the only place a user is told what this build can open, so it has
    /// to name every format the selector accepts. Adding a format without updating it fails here.
    func testTheRefusalSentenceNamesEveryAcceptedFormat() {
        let sentence = TweakHandlerError.unsupportedFileExtension("rar").localizedDescription
        for format in ArchiveFormat.allCases {
            for fileExtension in format.fileExtensions {
                XCTAssertTrue(
                    sentence.contains("." + fileExtension),
                    "The refusal sentence does not mention .\(fileExtension): \(sentence)"
                )
            }
        }
    }
}
