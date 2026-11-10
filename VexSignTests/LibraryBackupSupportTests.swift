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

    func testManifestRejectsFutureSchemaUnknownComponentsAndNegativeCounts() {
        var manifest = BackupManifest(version: 3, createdAt: Date(), appVersion: "1", contents: [.settings],
                                      includesTweaks: false, counts: nil, selectedCertUUID: nil, certificates: [], sources: [])
        XCTAssertNoThrow(try manifest.validateSupportedFormat())
        manifest.version = 4
        XCTAssertThrowsError(try manifest.validateSupportedFormat())
        manifest.version = 3
        manifest.contents = BackupComponents(rawValue: 1 << 20)
        XCTAssertThrowsError(try manifest.validateSupportedFormat())
        manifest.contents = [.settings]
        manifest.counts = ["4": -1]
        XCTAssertThrowsError(try manifest.validateSupportedFormat())
        manifest.counts = nil
        manifest.contents = [.library]
        manifest.version = 2
        manifest.apps = [entry()]
        XCTAssertThrowsError(try manifest.validateSupportedFormat())
    }

    private func cert(_ uuid: String) -> BackupManifest.Cert {
        BackupManifest.Cert(uuid: uuid, nickname: "Test", password: nil, expiration: Date(), ppq: false)
    }

    private func blankManifest(_ contents: BackupComponents) -> BackupManifest {
        BackupManifest(version: 3, createdAt: Date(), appVersion: "1", contents: contents,
            includesTweaks: false, counts: nil, selectedCertUUID: nil, certificates: [], sources: [])
    }

    func testManifestRejectsCertificateIdentifiersThatArePaths() {
        // A certificate's uuid is used as a directory name on both sides of a restore —
        // `certs/<uuid>` in the archive and `Certificates/<uuid>` in the app container — so a
        // manifest that names a path instead of an identifier is describing something this app
        // will never write. Distinctness was the only check before.
        var manifest = blankManifest([.certificates])
        let identifier = UUID().uuidString
        for spelling in [identifier.lowercased(), identifier.uppercased()] {
            manifest.certificates = [cert(spelling)]
            XCTAssertNoThrow(try manifest.validateSupportedFormat(), "real identifiers stay valid in either case")
        }

        for path in ["../../../../Library/Preferences/escape", "certs/../../escape", "", ".", "..",
                     identifier + "/../escape", "x", "not-a-uuid"] {
            manifest.certificates = [cert(path)]
            XCTAssertThrowsError(try manifest.validateSupportedFormat(), path)
        }
    }

    func testManifestRejectsSourcesThisBuildWillNotFetch() {
        // Restore bypasses the HTTPS requirement on purpose (a saved LAN repository has to keep
        // working), so the manifest has to be held to the rest of the policy instead: a scheme
        // and a host, no embedded credentials.
        var manifest = blankManifest([.sources])
        let rejected = ["file:///etc/passwd", "javascript:alert(1)", "https://user:secret@example.com/apps.json",
                        "https:apps.json", "ftp://example.com/apps.json"]
            .compactMap(URL.init(string:))
        XCTAssertGreaterThanOrEqual(rejected.count, 4, "the URLs under test must be representable")
        for url in rejected {
            manifest.sources = [.init(identifier: url.absoluteString, name: nil, url: url, iconURL: nil)]
            XCTAssertThrowsError(try manifest.validateSupportedFormat(), url.absoluteString)
        }

        let accepted = ["https://repo.example/apps.json", "http://192.168.1.10/repo.json", "HTTP://192.168.1.10/r.json"]
            .compactMap(URL.init(string:))
        XCTAssertEqual(accepted.count, 3)
        for url in accepted {
            manifest.sources = [.init(identifier: url.absoluteString, name: nil, url: url, iconURL: nil)]
            XCTAssertNoThrow(try manifest.validateSupportedFormat(), url.absoluteString)
        }

        // The icon URL is fetched by the same code, so it is held to the same rule.
        let good = URL(string: "https://repo.example/apps.json")!
        manifest.sources = [.init(identifier: "x", name: nil, url: good,
            iconURL: URL(string: "file:///etc/passwd"))]
        XCTAssertThrowsError(try manifest.validateSupportedFormat())
    }

    func testManifestWithNeitherCertificatesNorSourcesStillValidates() {
        // The two new checks must not make an ordinary settings backup unreadable.
        XCTAssertNoThrow(try blankManifest([.settings]).validateSupportedFormat())
        var library = blankManifest([.library])
        library.apps = [entry()]
        XCTAssertNoThrow(try library.validateSupportedFormat())
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
