//
//  PackageContentClassifierTests.swift
//  VexSignTests
//
//  A `.zip` is the one suffix that describes both an app someone zipped in Files
//  and a tweak bundle from a repository. The extension parser cannot tell them
//  apart, so the router asks this type. These tests pin the verdict for the
//  shapes that actually arrive, and pin the picker list to the same extensions
//  the importer accepts so the two cannot drift apart again.
//

import Foundation
import UniformTypeIdentifiers
import XCTest
import ZIPFoundation
@testable import VexSign

final class PackageContentClassifierTests: XCTestCase {
    private var root: URL!
    private let manager = FileManager.default

    override func setUpWithError() throws {
        root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? manager.removeItem(at: root) }
    }

    /// Builds a ZIP whose entries are `path: contents`. Directories are implied by
    /// the paths, which is how every packer but Xcode writes them.
    private func makeArchive(named name: String, entries: [String: String]) throws -> URL {
        let source = root.appendingPathComponent("source-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: source, withIntermediateDirectories: true)
        let archiveURL = root.appendingPathComponent(name)
        let archive = try Archive(url: archiveURL, accessMode: .create)
        for (path, contents) in entries.sorted(by: { $0.key < $1.key }) {
            // `addEntry` stores the file found at `source/<path>` under `<path>`,
            // so the fixture has to exist at that exact nested location. Sorting
            // the keys also fixes the entry order the scan limit is tested with.
            let file = source.appendingPathComponent(path)
            try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: file)
            try archive.addEntry(with: path, relativeTo: source, compressionMethod: .none)
        }
        return archiveURL
    }

    // MARK: - Application shapes

    func testIPAAndTIPAArchiveShapeIsAnApplication() throws {
        let ipa = try makeArchive(named: "Test.ipa", entries: [
            "Payload/Test.app/Info.plist": "<plist/>",
            "Payload/Test.app/Test": "binary",
            "iTunesMetadata.plist": "<plist/>"
        ])
        XCTAssertEqual(PackageContentClassifier.classify(at: ipa), .application)
    }

    func testRepackedBundleWithoutPayloadIsAnApplication() throws {
        // What Files produces when someone compresses a `.app` folder.
        let zip = try makeArchive(named: "Repacked.zip", entries: [
            "Test.app/Info.plist": "<plist/>",
            "Test.app/Test": "binary"
        ])
        XCTAssertEqual(PackageContentClassifier.classify(at: zip), .application)
    }

    func testLeadingDotSlashPrefixDoesNotHideAnAppBundle() throws {
        let zip = try makeArchive(named: "Dotted.zip", entries: [
            "./Payload/Test.app/Info.plist": "<plist/>"
        ])
        XCTAssertEqual(PackageContentClassifier.classify(at: zip), .application)
    }

    func testAnAppWithInjectedLibrariesIsStillAnApplication() throws {
        // A signed-with-tweaks IPA carries `.dylib` files inside the bundle. The
        // app shape wins, or the archive would be routed to the tweak manager and
        // the app dropped.
        let ipa = try makeArchive(named: "Injected.ipa", entries: [
            "Payload/Test.app/Info.plist": "<plist/>",
            "Payload/Test.app/Frameworks/Hook.dylib": "binary"
        ])
        XCTAssertEqual(PackageContentClassifier.classify(at: ipa), .application)
    }

    // MARK: - Tweak shapes

    func testRootDylibArchiveIsATweak() throws {
        let zip = try makeArchive(named: "Hook.zip", entries: [
            "Hook.dylib": "binary",
            "readme.txt": "how to install"
        ])
        XCTAssertEqual(PackageContentClassifier.classify(at: zip), .tweak)
    }

    func testRepositoryLibraryLayoutIsATweak() throws {
        let zip = try makeArchive(named: "Layout.zip", entries: [
            "Library/MobileSubstrate/DynamicLibraries/Hook.dylib": "binary",
            "Library/MobileSubstrate/DynamicLibraries/Hook.plist": "<plist/>"
        ])
        XCTAssertEqual(PackageContentClassifier.classify(at: zip), .tweak)
    }

    func testDebianControlIsATweak() throws {
        let zip = try makeArchive(named: "Package.deb", entries: [
            "DEBIAN/control": "Package: hook",
            "Layout/usr/lib/hook.dylib": "binary"
        ])
        XCTAssertEqual(PackageContentClassifier.classify(at: zip), .tweak)
    }

    // MARK: - Neither shape

    func testAnArchiveWithNoBundleAndNoTweakPayloadIsUnknown() throws {
        let zip = try makeArchive(named: "Notes.zip", entries: [
            "readme.txt": "nothing to install",
            "images/icon.png": "png"
        ])
        XCTAssertEqual(PackageContentClassifier.classify(at: zip), .unknown)
    }

    func testAnUnreadableFileIsUnknownRatherThanAnError() throws {
        let text = root.appendingPathComponent("notes.zip")
        try Data("not an archive".utf8).write(to: text)
        XCTAssertEqual(PackageContentClassifier.classify(at: text), .unknown)
        XCTAssertEqual(PackageContentClassifier.classify(at: root.appendingPathComponent("absent.zip")), .unknown)
    }

    func testScanLimitStopsBeforeTheIdentifyingEntry() throws {
        // The cap is what keeps a hostile archive from making routing cost more
        // than extraction; with it in play the verdict is the honest "unknown".
        let zip = try makeArchive(named: "Late.ipa", entries: [
            "A.txt": "1",
            "B.txt": "2",
            "Payload/Test.app/Info.plist": "<plist/>"
        ])
        XCTAssertEqual(PackageContentClassifier.classify(at: zip, scanLimit: 1), .unknown)
        XCTAssertEqual(PackageContentClassifier.classify(at: zip), .application)
    }

    // MARK: - Picker and importer agreement

    func testPickerOffersExactlyWhatTheImporterUnpacks() throws {
        XCTAssertEqual(PackageArchiveType.pickerExtensions, ["ipa", "tipa", "zip"])
        XCTAssertFalse(
            PackageArchiveType.pickerExtensions.contains("tgz"),
            "A gzipped tar has no reader here, so the picker must not offer one."
        )
        XCTAssertEqual(UTType.packageArchives.count, PackageArchiveType.pickerExtensions.count)
        // The type the app declares for a zipped app must be in the list the
        // picker is given, or the file is greyed out before it is ever opened.
        XCTAssertTrue(UTType.packageArchives.contains(.zip))
    }

    func testAcceptanceFollowsContentNotSuffix() throws {
        let zip = try makeArchive(named: "Renamed.tipa", entries: ["Payload/Test.app/Info.plist": "<plist/>"])
        XCTAssertTrue(PackageArchiveType.accepted(at: zip))
        XCTAssertNil(PackageArchiveType.rejectionReason(at: zip))

        let gz = root.appendingPathComponent("package.tgz")
        try Data([0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00]).write(to: gz)
        XCTAssertFalse(PackageArchiveType.accepted(at: gz))
        XCTAssertNotNil(PackageArchiveType.rejectionReason(at: gz))

        let text = root.appendingPathComponent("notes.ipa")
        try Data("not an archive".utf8).write(to: text)
        XCTAssertFalse(PackageArchiveType.accepted(at: text))
        XCTAssertNotNil(PackageArchiveType.rejectionReason(at: text))

        XCTAssertNotNil(PackageArchiveType.rejectionReason(at: root.appendingPathComponent("absent.ipa")))
    }

    func testCertificatePickerOffersEveryExtensionTheResolverReads() {
        // The screen used a literal list, so `.pfx` and `.provisionprofile` were
        // parsed by `CertificateImportBundle` and impossible to select.
        let offered = Set(CertificateImportBundle.pickerExtensions)
        XCTAssertTrue(offered.isSuperset(of: CertificateImportBundle.keyExtensions))
        XCTAssertTrue(offered.isSuperset(of: CertificateImportBundle.profileExtensions))
        XCTAssertEqual(UTType.certificateBundles.count, CertificateImportBundle.pickerExtensions.count)
    }
}
