import Foundation
import XCTest
import ZIPFoundation
@testable import VexSign

/// A standard IPA keeps its bundle in `Payload/`; a TIPA does not. Import used to
/// require the first layout and reject the second after unpacking it fully.
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

    func testTipaLayoutWithoutPayloadIsFoundAtTheTopLevel() throws {
        // A TIPA: the bundle sits beside the metadata, with no Payload folder.
        let app = root.appendingPathComponent("Tipa.app", isDirectory: true)
        try makeApp(app)
        try Data("metadata".utf8).write(to: root.appendingPathComponent("iTunesMetadata.plist"))

        // Import points at `<work>/Payload`, which does not exist for a TIPA.
        let expectedPayload = root.appendingPathComponent("Payload", isDirectory: true)
        XCTAssertEqual(try IPAImportPayload.application(in: expectedPayload), app)
    }

    func testTipaLayoutInsideOneFolderIsFound() throws {
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
        let zip = root.appendingPathComponent("renamed.tipa")
        do {
            let archive = try Archive(url: zip, accessMode: .create)
            try archive.addEntry(with: "Payload/", type: .directory, uncompressedSizeInBytes: 0)
        }
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
