import Foundation
import XCTest
@testable import VexSign

final class LibraryBackupSupportTests: XCTestCase {
    private func entry(uuid: String = UUID().uuidString, bundle: String = "Test.app") -> LibraryBackupEntry {
        LibraryBackupEntry(uuid: uuid, bundleName: bundle, signed: true, name: "Test", identifier: "test.app",
            originalIdentifier: "test.app", version: "1", appDescription: nil, certificateUUID: nil)
    }

    private func fixture(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    func testLibraryEntryRejectsUntrustedPathComponents() {
        XCTAssertNoThrow(try LibraryBackupSupport.validate(entry()))
        for uuid in ["../escape", "", "/tmp/escape"] {
            XCTAssertThrowsError(try LibraryBackupSupport.validate(entry(uuid: uuid)))
        }
        for name in ["../Test.app", "/Test.app", "nested\\Test.app", "Test.ipa", ".hidden.app"] {
            XCTAssertThrowsError(try LibraryBackupSupport.validate(entry(bundle: name)))
        }
    }

    func testLibraryByteLimitFailsRatherThanSilentlyOmittingFiles() throws {
        try fixture { root in
            try Data(repeating: 1, count: 10).write(to: root.appendingPathComponent("Test"))
            XCTAssertEqual(try LibraryBackupSupport.validateTree(root, maximumBytes: 10), 10)
            XCTAssertThrowsError(try LibraryBackupSupport.validateTree(root, maximumBytes: 9))
        }
    }

    func testLibraryTreeRejectsSymlinksAndMissingRoots() throws {
        try fixture { root in
            XCTAssertThrowsError(try LibraryBackupSupport.validateTree(root.appendingPathComponent("missing")))
            let file = root.appendingPathComponent("data")
            try Data([1]).write(to: file)
            XCTAssertThrowsError(try LibraryBackupSupport.validateTree(file))
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: file)
            XCTAssertThrowsError(try LibraryBackupSupport.validateTree(root))
        }
    }

    func testOldBackupManifestRemainsDecodableWithoutLibraryField() throws {
        let manifest = BackupManifest(version: 2, createdAt: Date(), appVersion: "1", contents: [.settings],
            includesTweaks: false, counts: nil, selectedCertUUID: nil, certificates: [], sources: [])
        let decoded = try JSONDecoder().decode(BackupManifest.self, from: JSONEncoder().encode(manifest))
        XCTAssertNil(decoded.apps)
        XCTAssertFalse(decoded.storedContents.contains(.library))
    }

    func testLibraryManifestRoundTripAndCounts() throws {
        var manifest = BackupManifest(version: 3, createdAt: Date(), appVersion: "1", contents: [.library],
            includesTweaks: false, counts: nil, selectedCertUUID: nil, certificates: [], sources: [])
        manifest.apps = [entry()]
        let decoded = try JSONDecoder().decode(BackupManifest.self, from: JSONEncoder().encode(manifest))
        XCTAssertEqual(decoded.count(of: .library), 1)
        XCTAssertTrue(decoded.storedContents.contains(.library))
        XCTAssertEqual(decoded.apps?.first?.identifier, "test.app")
    }
}
