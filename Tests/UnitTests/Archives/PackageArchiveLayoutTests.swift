import Foundation
import XCTest
@testable import VexSign

/// An IPA and a TIPA both keep the bundle in `Payload/`. A package repacked without
/// that folder was rejected after a full extraction; import now finds the bundle
/// while still refusing an archive that claims `Payload/` and leaves it empty.
final class PackageArchiveLayoutTests: XCTestCase {
    private var root: URL!
    private let manager = FileManager.default

    override func setUpWithError() throws {
        root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? manager.removeItem(at: root) }
    }

    private func makeApp(_ url: URL) throws {
        try manager.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: url.appendingPathComponent("App"))
    }

    func testStandardPayloadLayoutStillWins() throws {
        let payload = root.appendingPathComponent("Payload", isDirectory: true)
        let app = payload.appendingPathComponent("Test.app", isDirectory: true)
        try makeApp(app)
        XCTAssertEqual(try IPAImportPayload.application(in: payload), app)
    }

    func testTopLevelLayoutWithoutPayloadIsFound() throws {
        // A repacked app: the bundle sits beside the metadata, with no Payload folder.
        let app = root.appendingPathComponent("Tipa.app", isDirectory: true)
        try makeApp(app)
        try Data("metadata".utf8).write(to: root.appendingPathComponent("iTunesMetadata.plist"))

        // Import points at `<work>/Payload`, which in this layout does not exist.
        let expectedPayload = root.appendingPathComponent("Payload", isDirectory: true)
        XCTAssertEqual(try IPAImportPayload.application(in: expectedPayload), app)
    }

    func testLayoutInsideOneFolderIsFound() throws {
        let container = root.appendingPathComponent("Extracted", isDirectory: true)
        let app = container.appendingPathComponent("Nested.app", isDirectory: true)
        try makeApp(app)

        let expectedPayload = root.appendingPathComponent("Payload", isDirectory: true)
        XCTAssertEqual(try IPAImportPayload.application(in: expectedPayload), app)
    }

    func testAnEmptyPayloadIsStillRejectedRatherThanSearched() throws {
        // An archive that claims the IPA layout and leaves it empty is malformed; it
        // must not silently import an unrelated bundle from beside the Payload.
        try manager.createDirectory(at: root.appendingPathComponent("Payload"), withIntermediateDirectories: true)
        try makeApp(root.appendingPathComponent("Bystander.app", isDirectory: true))
        XCTAssertThrowsError(try IPAImportPayload.application(in: root.appendingPathComponent("Payload"))) { error in
            XCTAssertEqual(error as? IPAImportPayload.ValidationError, .missingApp)
        }
    }

    func testNestedAppsAreNotTopLevelCandidates() throws {
        let payload = root.appendingPathComponent("Payload", isDirectory: true)
        let app = payload.appendingPathComponent("Main.app", isDirectory: true)
        try makeApp(app)
        try manager.createDirectory(
            at: app.appendingPathComponent("Watch/Watch.app"),
            withIntermediateDirectories: true
        )
        XCTAssertEqual(try IPAImportPayload.application(in: payload), app)
    }

    func testContainerTypeIsDecidedByContentNotByExtension() throws {
        // Only the leading bytes matter for detection: a local file header is enough.
        let zip = root.appendingPathComponent("renamed.tipa")
        try Data([0x50, 0x4B, 0x03, 0x04, 0x14, 0x00, 0x00, 0x00]).write(to: zip)
        XCTAssertEqual(PackageArchiveType.detect(at: zip), PackageArchiveType.zip)

        let gz = root.appendingPathComponent("package.tgz")
        try Data([0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00]).write(to: gz)
        XCTAssertEqual(PackageArchiveType.detect(at: gz), PackageArchiveType.tarGzip)
        XCTAssertFalse(PackageArchiveType.tarGzip.canCarryAppPayload)

        let text = root.appendingPathComponent("notes.ipa")
        try Data("not an archive".utf8).write(to: text)
        XCTAssertEqual(PackageArchiveType.detect(at: text), PackageArchiveType.unsupported)
        XCTAssertEqual(PackageArchiveType.detect(at: root.appendingPathComponent("absent.ipa")), nil)
    }
}

/// The library stores app content, not the package the user imported.
final class PackageArchiveMoveTests: XCTestCase {
    func testWithoutAPayloadFolderOnlyTheAppBundleIsMoved() throws {
        // Mirrors `AppFileHandler.move()`: the work directory also holds the copied
        // archive, which must not end up inside the library entry.
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? manager.removeItem(at: work) }
        let library = work.appendingPathComponent("Library", isDirectory: true)
        let app = work.appendingPathComponent("Tipa.app", isDirectory: true)
        try manager.createDirectory(at: app, withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: app.appendingPathComponent("Tipa"))
        try Data("zip".utf8).write(to: work.appendingPathComponent("Tipa.tipa"))

        try manager.createDirectory(at: library, withIntermediateDirectories: true)
        let found = try IPAImportPayload.application(in: work)
        try manager.moveItem(at: found, to: library.appendingPathComponent(found.lastPathComponent))

        XCTAssertTrue(manager.fileExists(atPath: library.appendingPathComponent("Tipa.app/Tipa").path))
        XCTAssertFalse(manager.fileExists(atPath: library.appendingPathComponent("Tipa.tipa").path))
    }
}
