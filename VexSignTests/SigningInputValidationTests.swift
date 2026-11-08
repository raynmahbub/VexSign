import Foundation
import XCTest
@testable import VexSign

final class SigningInputValidationTests: XCTestCase {
    private func fixture(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func plist(_ value: Any, to url: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0).write(to: url)
    }

    func testCustomEntitlementsMustBeReadableDictionary() throws {
        try fixture { root in
            XCTAssertTrue(SigningInputValidation.entitlementsAreUsable(at: ""))
            let file = root.appendingPathComponent("entitlements.plist")
            XCTAssertFalse(SigningInputValidation.entitlementsAreUsable(at: file.path))
            try Data("not a plist".utf8).write(to: file)
            XCTAssertFalse(SigningInputValidation.entitlementsAreUsable(at: file.path))
            try plist(["get-task-allow"], to: file)
            XCTAssertFalse(SigningInputValidation.entitlementsAreUsable(at: file.path))
            try plist(["get-task-allow": true], to: file)
            XCTAssertTrue(SigningInputValidation.entitlementsAreUsable(at: file.path))
            try plist([String: String](), to: file)
            XCTAssertTrue(SigningInputValidation.entitlementsAreUsable(at: file.path))
        }
    }

    func testExecutableMustExistAndBeRegularFile() throws {
        try fixture { root in
            let metadata = root.appendingPathComponent("Info.plist")
            try plist(["CFBundleExecutable": "Test"], to: metadata)
            XCTAssertNil(SigningInputValidation.executable(in: root))
            let binary = root.appendingPathComponent("Test")
            try FileManager.default.createDirectory(at: binary, withIntermediateDirectories: true)
            XCTAssertNil(SigningInputValidation.executable(in: root))
            try FileManager.default.removeItem(at: binary)
            try Data([0xcf, 0xfa, 0xed, 0xfe]).write(to: binary)
            XCTAssertEqual(SigningInputValidation.executable(in: root), binary.resolvingSymlinksInPath().standardizedFileURL)
        }
    }

    func testExecutableNameCannotTraverseDirectories() throws {
        try fixture { root in
            for name in ["", ".", "..", "../outside", "/tmp/outside", "nested/Test", "nested\\Test", "Test\0"] {
                try plist(["CFBundleExecutable": name], to: root.appendingPathComponent("Info.plist"))
                XCTAssertNil(SigningInputValidation.executable(in: root), name)
            }
        }
    }

    func testExecutableSymlinkCannotEscapeBundle() throws {
        try fixture { root in
            let bundle = root.appendingPathComponent("Test.app")
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            let outside = root.appendingPathComponent("outside")
            try Data([1]).write(to: outside)
            try plist(["CFBundleExecutable": "Test"], to: bundle.appendingPathComponent("Info.plist"))
            try FileManager.default.createSymbolicLink(at: bundle.appendingPathComponent("Test"), withDestinationURL: outside)
            XCTAssertNil(SigningInputValidation.executable(in: bundle))
        }
    }
}
