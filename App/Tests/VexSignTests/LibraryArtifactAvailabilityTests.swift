//
//  LibraryArtifactAvailabilityTests.swift
//  VexSignTests
//
//  A library row and the bundle it points at are two different things. These tests pin the rule
//  that tells them apart, plus the one place the store asks it.
//
//  The rule is exercised through `Facts` — a value type — so nothing here touches the filesystem
//  except the two tests that deliberately do.
//

import Foundation
import XCTest
@testable import VexSign

final class LibraryArtifactAvailabilityTests: XCTestCase {
    // MARK: - The rule

    func testADirectoryThatIsGoneIsMissingNotIncomplete() {
        let state = LibraryArtifactInspector.state(for: .init(bundleDirectoryExists: false))
        XCTAssertEqual(state, .missing)
        XCTAssertNotNil(state.title)
        XCTAssertNotNil(state.detail)
        XCTAssertFalse(state.isUsable)
    }

    func testMissingAndIncompleteGiveDifferentAdvice() {
        // "Import it again" and "the bundle is damaged" are not the same instruction.
        XCTAssertNotEqual(
            LibraryArtifactInspector.state(for: .init(bundleDirectoryExists: false)).detail,
            LibraryArtifactInspector.state(for: .init(bundleDirectoryExists: true)).detail
        )
    }

    func testAPresentDirectoryWithoutInfoPlistIsIncomplete() {
        let state = LibraryArtifactInspector.state(for: .init(bundleDirectoryExists: true, infoPlistExists: false))
        guard case .incomplete(let reason) = state else { return XCTFail("expected incomplete, got \(state)") }
        XCTAssertTrue(reason.localizedCaseInsensitiveContains("Info.plist"))
    }

    func testAMissingExecutableIsIncompleteWhenTheNameIsKnown() {
        let facts = LibraryArtifactInspector.Facts(
            bundleDirectoryExists: true, infoPlistExists: true,
            executableName: "Test", executableExists: false
        )
        guard case .incomplete = LibraryArtifactInspector.state(for: facts) else {
            return XCTFail("a named executable that is gone must be incomplete")
        }
    }

    func testAnUnknownExecutableNameIsNotTreatedAsMissing() {
        // Unsigned imports do not always carry an executable name; the absence of the *name* is
        // not evidence that the binary is gone.
        let facts = LibraryArtifactInspector.Facts(
            bundleDirectoryExists: true, infoPlistExists: true,
            executableName: nil, executableExists: false
        )
        XCTAssertEqual(LibraryArtifactInspector.state(for: facts), .available)
    }

    func testAnEmptyBundleIsIncomplete() {
        let facts = LibraryArtifactInspector.Facts(
            bundleDirectoryExists: true, infoPlistExists: true, byteCount: 0
        )
        guard case .incomplete = LibraryArtifactInspector.state(for: facts) else {
            return XCTFail("a zero-byte bundle must be incomplete")
        }
    }

    func testAnUnknownSizeIsNotEvidence() {
        let facts = LibraryArtifactInspector.Facts(
            bundleDirectoryExists: true, infoPlistExists: true, byteCount: nil
        )
        XCTAssertEqual(LibraryArtifactInspector.state(for: facts), .available)
    }

    func testACompleteBundleIsAvailableAndStaysSilent() {
        let state = LibraryArtifactInspector.state(for: .init(
            bundleDirectoryExists: true, infoPlistExists: true,
            executableName: "Test", executableExists: true, byteCount: 4096
        ))
        XCTAssertEqual(state, .available)
        XCTAssertTrue(state.isUsable)
        XCTAssertNil(state.title, "an available row must not show a badge")
        XCTAssertNil(state.detail)
    }

    func testUnknownIsNeverRenderedAsAProblem() {
        XCTAssertNil(LibraryArtifactState.unknown.title)
        XCTAssertFalse(LibraryArtifactState.unknown.isUsable)
    }

    // MARK: - The filesystem adapter

    func testFactsReportAMissingDirectoryAsNotExisting() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertEqual(LibraryArtifactInspector.facts(of: url), .init(bundleDirectoryExists: false))
        XCTAssertEqual(LibraryArtifactInspector.read(url), .missing)
    }

    func testFactsOfARealBundleAreAvailable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Artifact-\(UUID().uuidString)")
        let bundle = root.appendingPathComponent("Test.app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) } // try? ok: test cleanup, nothing to report
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleExecutable": "Test"], format: .xml, options: 0
        )
        try plist.write(to: bundle.appendingPathComponent("Info.plist"))
        try Data(repeating: 0x61, count: 1024).write(to: bundle.appendingPathComponent("Test"))

        XCTAssertEqual(LibraryArtifactInspector.read(bundle), .available)

        // Remove the executable only: the directory and Info.plist are still there, so the answer
        // must be "incomplete" rather than "missing".
        try FileManager.default.removeItem(at: bundle.appendingPathComponent("Test"))
        let state = LibraryArtifactInspector.read(bundle)
        guard case .incomplete = state else { return XCTFail("expected incomplete, got \(state)") }
    }

    func testAPlistThatNamesNoExecutableLeavesTheBundleAvailable() throws {
        // No evidence about the executable is not evidence that it is missing.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Artifact-\(UUID().uuidString)")
        let bundle = root.appendingPathComponent("Test.app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) } // try? ok: test cleanup, nothing to report
        try Data(repeating: 0x61, count: 64).write(to: bundle.appendingPathComponent("Payload"))

        for contents in [Data("not a plist".utf8),
                         try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "../Other"], format: .xml, options: 0)] {
            try contents.write(to: bundle.appendingPathComponent("Info.plist"))
            XCTAssertEqual(LibraryArtifactInspector.read(bundle), .available)
        }
    }

    // MARK: - Store wiring

    private func request(bundleURL: URL?, isSigned: Bool = false) -> LibraryStatusStore.Request {
        LibraryStatusStore.Request(
            uuid: "uuid", bundleIdentifier: "com.example.test",
            expectedVersion: "1.0", bundleURL: bundleURL, isSigned: isSigned
        )
    }

    func testResolveAsksTheFilesystemForAnyRowWithABundle() {
        // Independent of signing: an unsigned app whose files were deleted is just as broken.
        let bundle = URL(fileURLWithPath: "/tmp/does-not-matter")
        let status = LibraryStatusStore.resolve(
            request(bundleURL: bundle),
            installedApp: nil,
            readSignature: { _ in .noCodeSignature },
            readGuest: { _ in .unavailable },
            readArtifact: { _ in .missing }
        )
        XCTAssertEqual(status.artifact, .missing)
    }

    func testResolveLeavesArtifactUnknownWithoutABundle() {
        let status = LibraryStatusStore.resolve(
            request(bundleURL: nil),
            installedApp: nil,
            readSignature: { _ in .noCodeSignature },
            readGuest: { _ in .unavailable },
            readArtifact: { _ in .available }
        )
        XCTAssertEqual(status.artifact, .unknown, "a row with no bundle location has not been read")
    }

    func testResolveKeepsSignatureAndArtifactIndependent() {
        let status = LibraryStatusStore.resolve(
            request(bundleURL: URL(fileURLWithPath: "/tmp/bundle"), isSigned: true),
            installedApp: nil,
            readSignature: { _ in .noCertificates },
            readGuest: { _ in .unavailable },
            readArtifact: { _ in .missing }
        )
        XCTAssertEqual(status.artifact, .missing)
        XCTAssertEqual(status.signature, .noCertificates, "a missing bundle does not erase what the signature read said")
    }
}
