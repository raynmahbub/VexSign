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
