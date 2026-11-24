import XCTest
@testable import VexSign

final class ArchiveTransferPolicyTests: XCTestCase {
    func testPairingUsesFastCompressionInsteadOfUncompressedPayload() {
        XCTAssertEqual(ArchiveTransferPolicy.compression(storedIndex: 0, compressForTransfer: true), .bestSpeed)
    }

    func testExportAndOtherPathsPreserveUserCompression() {
        for (index, selected) in ArchiveCompression.allCases.enumerated() {
            XCTAssertEqual(ArchiveTransferPolicy.compression(storedIndex: index, compressForTransfer: false), selected)
        }
    }

    func testPairingPreservesExplicitCompressionLevels() {
        for index in 1..<ArchiveCompression.allCases.count {
            XCTAssertEqual(ArchiveTransferPolicy.compression(storedIndex: index, compressForTransfer: true), ArchiveCompression.allCases[index])
        }
    }

    func testInvalidSettingsFallBackWithoutIndexingCrash() {
        for index in [-1, Int.min, 4, Int.max] {
            for transfer in [false, true] {
                XCTAssertEqual(ArchiveTransferPolicy.compression(storedIndex: index, compressForTransfer: transfer), .defaultCompression)
            }
        }
    }

    func testArchiveEngineRoundTripsMultipleItemsWithIPAExtractor() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ArchiveRoundTrip-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let fileA = root.appendingPathComponent("cert.p12")
        let fileB = root.appendingPathComponent("profile.mobileprovision")
        let password = root.appendingPathComponent("password.txt")
        try Data("p12-bytes".utf8).write(to: fileA)
        try Data("provision-bytes".utf8).write(to: fileB)
        try Data("secret123".utf8).write(to: password)

        let zipURL = root.appendingPathComponent("export.zip")
        try ArchiveEngine.zipItems([fileA, fileB, password], to: zipURL)

        let extracted = root.appendingPathComponent("out", isDirectory: true)
        try IPAExtractor.extract(zipURL, to: extracted)

        XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent("cert.p12")), Data("p12-bytes".utf8))
        XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent("profile.mobileprovision")), Data("provision-bytes".utf8))
        XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent("password.txt")), Data("secret123".utf8))
    }

    func testAppArchiverPreservesExistingOutputAndSiblingZipWhenPackagingFails() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ArchiveFailure-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let ipa = root.appendingPathComponent("App.ipa")
        let sibling = root.appendingPathComponent("App.zip")
        let oldIPA = Data("previous ipa".utf8)
        let oldZip = Data("unrelated zip".utf8)
        try oldIPA.write(to: ipa)
        try oldZip.write(to: sibling)

        XCTAssertThrowsError(try AppArchiver.zip(payload: root.appendingPathComponent("missing"), to: ipa, compression: .defaultCompression))
        XCTAssertEqual(try Data(contentsOf: ipa), oldIPA)
        XCTAssertEqual(try Data(contentsOf: sibling), oldZip)
        XCTAssertFalse(try fm.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".VexSignArchive-") })
    }

    func testAppArchiverReplacesOutputOnlyAfterSuccessfulPackaging() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ArchivePublish-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let payload = root.appendingPathComponent("Payload", isDirectory: true)
        let app = payload.appendingPathComponent("Sample.app", isDirectory: true)
        try fm.createDirectory(at: app, withIntermediateDirectories: true)
        try Data("new contents".utf8).write(to: app.appendingPathComponent("Info.plist"))
        let ipa = root.appendingPathComponent("App.ipa")
        let sibling = root.appendingPathComponent("App.zip")
        try Data("old output".utf8).write(to: ipa)
        try Data("unrelated".utf8).write(to: sibling)

        var progress: [Double] = []
        try AppArchiver.zip(payload: payload, to: ipa, compression: .defaultCompression) { progress.append($0) }
        XCTAssertEqual(progress.last, 1)
        XCTAssertTrue(progress.dropLast().allSatisfy { $0 < 1 })
        let extracted = root.appendingPathComponent("extracted", isDirectory: true)
        try IPAExtractor.extract(ipa, to: extracted)
        XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent("Payload/Sample.app/Info.plist")), Data("new contents".utf8))
        XCTAssertEqual(try Data(contentsOf: sibling), Data("unrelated".utf8))
        XCTAssertFalse(try fm.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".VexSignArchive-") })
    }

    func testAppArchiverSupportsZipAsTheOutputExtension() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ArchiveZip-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let payload = root.appendingPathComponent("Payload", isDirectory: true)
        try fm.createDirectory(at: payload, withIntermediateDirectories: true)
        try Data("data".utf8).write(to: payload.appendingPathComponent("file"))
        let output = root.appendingPathComponent("archive.zip")
        try AppArchiver.zip(payload: payload, to: output, compression: .noCompression)
        let extracted = root.appendingPathComponent("out", isDirectory: true)
        try IPAExtractor.extract(output, to: extracted)
        XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent("Payload/file")), Data("data".utf8))
    }

    func testArchiveEngineZipDirectoryPreservesParentFolderWithNoCompression() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ArchiveDir-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let payloadDir = root.appendingPathComponent("Payload", isDirectory: true)
        let appDir = payloadDir.appendingPathComponent("Sample.app", isDirectory: true)
        try fm.createDirectory(at: appDir, withIntermediateDirectories: true)
        try Data("plist-bytes".utf8).write(to: appDir.appendingPathComponent("Info.plist"))

        let ipaURL = root.appendingPathComponent("Sample.ipa")
        try ArchiveEngine.zipDirectory(payloadDir, to: ipaURL, compression: .noCompression)

        let extracted = root.appendingPathComponent("extracted", isDirectory: true)
        try IPAExtractor.extract(ipaURL, to: extracted)
        let extractedPlist = extracted.appendingPathComponent("Payload/Sample.app/Info.plist")
        XCTAssertEqual(try Data(contentsOf: extractedPlist), Data("plist-bytes".utf8))
    }
}
