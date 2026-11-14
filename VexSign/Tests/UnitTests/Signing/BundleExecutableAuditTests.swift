import XCTest
@testable import VexSign

final class BundleExecutableAuditTests: XCTestCase {
    private func fixture(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("Root.app")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) } // try? ok: test teardown
        try bundle(root)
        try body(root)
    }

    private func bundle(_ url: URL, encrypted: Bool = false) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let plist: [String: String] = ["CFBundleIdentifier": "com.fixture.app", "CFBundleExecutable": "Fixture"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: url.appendingPathComponent("Info.plist"))
        let words: [UInt32] = [0xfeedfacf, 0x0100000c, 0, 2, 2, 48, 0, 0,
                               0x32, 24, 2, 0x00110000, 0, 0, 0x2c, 24, 0, 0, encrypted ? 1 : 0, 0]
        var data = Data()
        for word in words { var value = word.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        try data.write(to: url.appendingPathComponent("Fixture"))
    }

    func testNestedEncryptionIsNotHiddenByCleanMainExecutable() throws {
        try fixture { root in
            try bundle(root.appendingPathComponent("PlugIns/Widget.appex"), encrypted: true)
            let report = try BundleExecutableAudit.inspect(root)
            XCTAssertEqual(report.inspected, 2)
            XCTAssertEqual(report.blocking.map(\.problem), [.encrypted])
            XCTAssertThrowsError(try BundleExecutableAudit.requireSignable(root))
            let stripped = try BundleExecutableAudit.inspect(root, excludingBundlePaths: ["PlugIns/Widget.appex"])
            XCTAssertTrue(stripped.blocking.isEmpty)
            XCTAssertEqual(stripped.inspected, 1)
        }
    }

    func testCleanBundleAndEntryBudget() throws {
        try fixture { root in
            XCTAssertNoThrow(try BundleExecutableAudit.requireSignable(root))
            XCTAssertThrowsError(try BundleExecutableAudit.inspect(root, maximumEntries: 0))
        }
    }

    func testDeclaredExecutableCannotEscapeBundle() throws {
        try fixture { root in
            let executable = root.appendingPathComponent("Fixture")
            try FileManager.default.removeItem(at: executable)
            try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: root.deletingLastPathComponent().appendingPathComponent("outside"))
            let report = try BundleExecutableAudit.inspect(root)
            XCTAssertTrue(report.blocking.contains(where: { $0.problem == .unreadable }))
            XCTAssertThrowsError(try BundleExecutableAudit.requireSignable(root))
        }
    }
}
