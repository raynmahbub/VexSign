import Foundation
import XCTest
import ZIPFoundation
@testable import VexSign

/// Certificate import used to demand two separate picks, which is not how a
/// certificate is handed out: it arrives as one `.zip` (or folder) holding the
/// `.p12` and its `.mobileprovision`.
final class CertificateImportBundleTests: XCTestCase {
    private var root: URL!
    private let manager = FileManager.default

    override func setUpWithError() throws {
        root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? manager.removeItem(at: root) }
    }

    private func write(_ name: String, in directory: URL, contents: String = "bytes") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func makeBundle(at archiveURL: URL, entries: [(String, String)]) throws {
        let source = root.appendingPathComponent("source-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: source, withIntermediateDirectories: true)
        for (name, contents) in entries { _ = try write(name, in: source, contents: contents) }
        let archive = try Archive(url: archiveURL, accessMode: .create)
        for (name, _) in entries { try archive.addEntry(with: name, relativeTo: source) }
    }

    func testAZipHoldingBothFilesIsResolvedAndCleanedUp() throws {
        let archive = root.appendingPathComponent("certificate.zip")
        try makeBundle(at: archive, entries: [
            ("cert.p12", "key-bytes"),
            ("cert.mobileprovision", "profile-bytes"),
            ("password.txt", "secret")
        ])

        let resolved = try CertificateImportBundle.resolve(archive)
        XCTAssertEqual(resolved.key.pathExtension, "p12")
        XCTAssertEqual(resolved.profile.pathExtension, "mobileprovision")
        XCTAssertNil(CertificateImportBundle.missingRole(resolved))
        XCTAssertEqual(try Data(contentsOf: resolved.key), Data("key-bytes".utf8))
        XCTAssertEqual(try Data(contentsOf: resolved.profile), Data("profile-bytes".utf8))

        let staging = try XCTUnwrap(resolved.staging)
        XCTAssertTrue(manager.fileExists(atPath: staging.path))
        try manager.removeItem(at: staging)
        XCTAssertFalse(manager.fileExists(atPath: staging.path))
    }

    func testFilesMaySitInOneFolderInsideTheZip() throws {
        // Providers usually nest both files in one folder rather than at the root.
        let source = root.appendingPathComponent("nested", isDirectory: true)
        let folder = source.appendingPathComponent("MyCertificate", isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = try write("key.p12", in: folder)
        _ = try write("key.mobileprovision", in: folder)

        let archive = root.appendingPathComponent("nested.zip")
        let zip = try Archive(url: archive, accessMode: .create)
        try zip.addEntry(with: "MyCertificate/key.p12", relativeTo: source)
        try zip.addEntry(with: "MyCertificate/key.mobileprovision", relativeTo: source)

        let resolved = try CertificateImportBundle.resolve(archive)
        XCTAssertEqual(resolved.key.lastPathComponent, "key.p12")
        XCTAssertEqual(resolved.profile.lastPathComponent, "key.mobileprovision")
        if let staging = resolved.staging { try manager.removeItem(at: staging) }
    }

    func testAProfileOnlyArchiveNamesWhatIsMissing() throws {
        let archive = root.appendingPathComponent("profile-only.zip")
        try makeBundle(at: archive, entries: [("cert.mobileprovision", "profile-bytes")])
        XCTAssertThrowsError(try CertificateImportBundle.resolve(archive)) { error in
            XCTAssertEqual(error as? CertificateImportBundle.Problem, .missingKey)
        }
    }

    func testAKeyOnlyArchiveNamesWhatIsMissing() throws {
        let archive = root.appendingPathComponent("key-only.zip")
        try makeBundle(at: archive, entries: [("cert.p12", "key-bytes")])
        XCTAssertThrowsError(try CertificateImportBundle.resolve(archive)) { error in
            XCTAssertEqual(error as? CertificateImportBundle.Problem, .missingProfile)
        }
    }

    func testTwoCertificatesAreRefusedInsteadOfPickingOne() throws {
        let archive = root.appendingPathComponent("two-keys.zip")
        try makeBundle(at: archive, entries: [
            ("first.p12", "a"), ("second.p12", "b"), ("cert.mobileprovision", "profile")
        ])
        XCTAssertThrowsError(try CertificateImportBundle.resolve(archive)) { error in
            XCTAssertEqual(error as? CertificateImportBundle.Problem, .ambiguous(.key))
        }
    }

    func testAnUnreadableArchiveIsReportedAsDamageNotAsAPasswordProblem() throws {
        let archive = root.appendingPathComponent("broken.zip")
        try Data("PK\u{3}\u{4}not really a zip".utf8).write(to: archive)
        XCTAssertThrowsError(try CertificateImportBundle.resolve(archive)) { error in
            XCTAssertEqual(error as? CertificateImportBundle.Problem, .archiveUnreadable)
        }
    }

    func testSingleFilesPassThroughUntouched() throws {
        let key = try write("cert.p12", in: root)
        let resolvedKey = try CertificateImportBundle.resolve(key)
        XCTAssertEqual(resolvedKey.key, key)
        XCTAssertNil(resolvedKey.staging)
        // A `.p12` on its own is still an incomplete pair, and says so.
        XCTAssertEqual(CertificateImportBundle.missingRole(resolvedKey), .missingProfile)

        let profile = try write("cert.mobileprovision", in: root)
        XCTAssertEqual(CertificateImportBundle.missingRole(try CertificateImportBundle.resolve(profile)), .missingKey)
    }

    func testAFolderSelectionIsResolvedInPlace() throws {
        _ = try write("cert.p12", in: root)
        _ = try write("cert.mobileprovision", in: root)
        let resolved = try CertificateImportBundle.resolve(root)
        XCTAssertEqual(resolved.key.lastPathComponent, "cert.p12")
        XCTAssertEqual(resolved.profile.lastPathComponent, "cert.mobileprovision")
        // Nothing was extracted, so nothing is deleted afterwards.
        XCTAssertNil(resolved.staging)
    }
}
