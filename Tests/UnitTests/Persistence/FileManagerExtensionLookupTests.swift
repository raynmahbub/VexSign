import Foundation
import XCTest
@testable import VexSign

final class FileManagerExtensionLookupTests: XCTestCase {
    func testGetPathMatchesCaseInsensitiveExtension() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ExtensionLookup-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) } // try? ok: remove the temporary test directory

        let profile = root.appendingPathComponent("identity.MobileProvision")
        try Data("profile".utf8).write(to: profile)
        let appBundle = root.appendingPathComponent("Test.APP", isDirectory: true)
        try FileManager.default.createDirectory(at: appBundle, withIntermediateDirectories: false)

        XCTAssertEqual(FileManager.default.getPath(in: root, for: "mobileprovision"), profile)
        XCTAssertEqual(FileManager.default.getPath(in: root, for: "app"), appBundle)
    }

    func testGetPathStillRequiresTheRequestedExtension() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ExtensionLookup-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) } // try? ok: remove the temporary test directory

        let profile = root.appendingPathComponent("identity.mobileprovision")
        try Data("profile".utf8).write(to: profile)

        XCTAssertNil(FileManager.default.getPath(in: root, for: "p12"))
    }
}
