//
//  TweakPackageTests.swift
//  VexSignTests
//
//  `DebianDataMember` and `TweakPlacement` decide what a tweak package may contribute to a signed
//  app, and until now they could only be reached through `TweakHandler`'s live session: the
//  refusals that matter — no payload, two payloads, an unknown compression, a name collision —
//  were untested. They are pure, so they are tested here.
//

import Foundation
import XCTest
@testable import VexSign

final class TweakPackageTests: XCTestCase {
    // MARK: - Selecting the payload

    func testOneDataMemberIsSelectedWhateverItsCompression() throws {
        for format in ArchiveFormat.allCases {
            for fileExtension in format.fileExtensions {
                let member = "data.tar." + fileExtension
                XCTAssertEqual(try DebianDataMember.select(from: ["control.tar.gz", member]), member)
            }
        }
        XCTAssertEqual(try DebianDataMember.select(from: ["data.tar"]), "data.tar")
    }

    func testAPackageWithoutADataMemberIsRefused() {
        XCTAssertThrowsError(try DebianDataMember.select(from: [])) {
            XCTAssertEqual($0 as? DebianDataMember.SelectionError, .missing)
        }
        XCTAssertThrowsError(try DebianDataMember.select(from: ["control.tar.gz", "debian-binary"])) {
            XCTAssertEqual($0 as? DebianDataMember.SelectionError, .missing)
        }
    }

    func testTwoDataMembersAreRefusedRatherThanGuessed() {
        // A package that ships both an uncompressed and a compressed payload has no single answer,
        // and picking one silently would inject something the packager did not mean.
        XCTAssertThrowsError(try DebianDataMember.select(from: ["data.tar", "data.tar.gz"])) {
            XCTAssertEqual($0 as? DebianDataMember.SelectionError, .multiple)
        }
        XCTAssertThrowsError(try DebianDataMember.select(from: ["data.tar.xz", "data.tar.zst"])) {
            XCTAssertEqual($0 as? DebianDataMember.SelectionError, .multiple)
        }
    }

    func testAnUnknownCompressionIsNamedInTheRefusal() throws {
        do {
            _ = try DebianDataMember.select(from: ["data.tar.lz4"])
            XCTFail("data.tar.lz4 is not a format this build decodes")
        } catch let error as DebianDataMember.SelectionError {
            XCTAssertEqual(error, .unsupported("data.tar.lz4"))
            XCTAssertTrue(try XCTUnwrap(error.errorDescription).contains("data.tar.lz4"))
        }
    }

    // MARK: - Extraction steps

    func testACompressedMemberNeedsOneMoreStepThanAnUncompressedOne() {
        XCTAssertEqual(DebianDataMember.extractionPasses(for: "data.tar"), 1)
        for member in ArchiveFormat.debianDataMembers where member != "data.tar" {
            XCTAssertEqual(DebianDataMember.extractionPasses(for: member), 2, member)
        }
    }

    func testOnlyTheUncompressedMemberHasNoFormat() {
        XCTAssertNil(ArchiveFormat.debianMember("data.tar"))
        for member in ArchiveFormat.debianDataMembers where member != "data.tar" {
            XCTAssertNotNil(ArchiveFormat.debianMember(member), member)
            XCTAssertEqual(DebianDataMember.extractionPasses(for: member), 2, member)
        }
    }

    // MARK: - Placement

    func testAPlacementNeverOverwritesAnExistingItem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock {
            do { try FileManager.default.removeItem(at: root) } catch { XCTFail("left \(root) behind") }
        }
        let source = root.appendingPathComponent("Incoming.framework")
        let destinationDirectory = root.appendingPathComponent("Payload/Frameworks")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let destination = destinationDirectory.appendingPathComponent("Incoming.framework")

        try TweakPlacement.move(source, to: destination)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))

        // A second item with the same name is a conflict the user is told about, not an overwrite.
        let second = root.appendingPathComponent("Second/Incoming.framework")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        XCTAssertThrowsError(try TweakPlacement.move(second, to: destination)) { error in
            XCTAssertTrue(error is TweakPlacement.Conflict)
            XCTAssertTrue(error.localizedDescription.contains("Incoming.framework"))
        }
    }
}
