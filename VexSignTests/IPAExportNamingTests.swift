import Foundation
import XCTest
@testable import VexSign

final class IPAExportNamingTests: XCTestCase {
    private func fixture(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    func testReadableNameAndFallbacks() {
        XCTAssertEqual(IPAExportNaming.stem(name: " My App ", version: " 1.2 "), "My App 1.2")
        XCTAssertEqual(IPAExportNaming.stem(name: nil, version: nil), "App")
        XCTAssertEqual(IPAExportNaming.stem(name: "...", version: " "), "App")
        XCTAssertEqual(IPAExportNaming.stem(name: "My App", version: nil), "My App")
    }

    func testUnsafePathAndControlCharactersAreReplaced() {
        let stem = IPAExportNaming.stem(name: "../My/App\\Name:\n", version: "1?2")
        XCTAssertFalse(stem.contains("/"))
        XCTAssertFalse(stem.contains("\\"))
        XCTAssertFalse(stem.contains(":"))
        XCTAssertFalse(stem.contains("?"))
        XCTAssertFalse(stem.hasPrefix("."))
        XCTAssertFalse(stem.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
    }

    func testUnicodeBudgetPreservesWholeCharacters() {
        let grapheme = "👨‍👩‍👧‍👦"
        let stem = IPAExportNaming.stem(name: String(repeating: grapheme, count: 100), version: "1")
        XCTAssertLessThanOrEqual(stem.decomposedStringWithCanonicalMapping.utf8.count, 180)
        XCTAssertFalse(stem.isEmpty)
        XCTAssertTrue(stem.allSatisfy { String($0) == grapheme })
        let accented = IPAExportNaming.stem(name: String(repeating: "é", count: 500), version: nil)
        XCTAssertLessThanOrEqual(accented.decomposedStringWithCanonicalMapping.utf8.count, 180)
    }

    func testRepeatedExportsNeverOverwriteExistingPackages() throws {
        try fixture { root in
            let archives = root.appendingPathComponent("Archives")
            for number in 1...3 {
                let source = root.appendingPathComponent("source.ipa")
                let content = Data([UInt8(number)])
                try content.write(to: source)
                let result = try IPAExportNaming.movePackage(source, to: archives, name: "Test", version: "1")
                let suffix = number == 1 ? "" : " (\(number))"
                XCTAssertEqual(result.lastPathComponent, "Test 1\(suffix).ipa")
                XCTAssertEqual(try Data(contentsOf: result), content)
                XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
            }
            XCTAssertEqual(try Data(contentsOf: archives.appendingPathComponent("Test 1.ipa")), Data([1]))
        }
    }

    func testMissingSourceThrowsInsteadOfReturningAnUnwrittenDestination() throws {
        try fixture { root in
            let archives = root.appendingPathComponent("Archives")
            XCTAssertThrowsError(try IPAExportNaming.movePackage(root.appendingPathComponent("missing.ipa"), to: archives, name: "Test", version: nil))
            XCTAssertFalse(FileManager.default.fileExists(atPath: archives.appendingPathComponent("Test.ipa").path))
        }
    }

    func testFailedDestinationPreservesSource() throws {
        try fixture { root in
            let source = root.appendingPathComponent("source.ipa")
            let blocked = root.appendingPathComponent("not-a-directory")
            let bytes = Data([1, 2, 3])
            try bytes.write(to: source)
            try Data([0]).write(to: blocked)
            XCTAssertThrowsError(try IPAExportNaming.movePackage(source, to: blocked, name: "Test", version: nil))
            XCTAssertEqual(try Data(contentsOf: source), bytes)
        }
    }
}
