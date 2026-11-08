import Foundation
import XCTest
@testable import VexSign

final class TweakImportSupportTests: XCTestCase {
    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func libraryHeader() -> Data {
        var bytes = Data(repeating: 0, count: 32)
        bytes.replaceSubrange(0..<4, with: [0xcf, 0xfa, 0xed, 0xfe])
        return bytes
    }

    func testAcceptsMachOAndDebHeaders() throws {
        try withDirectory { root in
            let library = root.appendingPathComponent("Valid.dylib")
            try libraryHeader().write(to: library)
            XCTAssertNoThrow(try TweakImportSupport.validate(library))
            let deb = root.appendingPathComponent("Valid.deb")
            try Data("!<arch>\n".utf8).write(to: deb)
            XCTAssertNoThrow(try TweakImportSupport.validate(deb))
        }
    }

    func testRejectsWrongHeaderAndUnsupportedExtension() throws {
        try withDirectory { root in
            for name in ["Broken.dylib", "Broken.deb", "Broken.txt"] {
                let url = root.appendingPathComponent(name)
                try Data(repeating: 65, count: 64).write(to: url)
                XCTAssertThrowsError(try TweakImportSupport.validate(url))
            }
        }
    }

    func testRejectsDirectoryMasqueradingAsDylib() throws {
        try withDirectory { root in
            let url = root.appendingPathComponent("Fake.dylib", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            XCTAssertThrowsError(try TweakImportSupport.validate(url))
        }
    }

    func testChecksSizeBeforeReading() throws {
        try withDirectory { root in
            let url = root.appendingPathComponent("Oversize.dylib")
            try libraryHeader().write(to: url)
            XCTAssertThrowsError(try TweakImportSupport.validate(url, maximumBytes: 16))
        }
    }

    func testRejectsRootAndNestedSymlinks() throws {
        try withDirectory { root in
            let source = root.appendingPathComponent("Source.dylib")
            try libraryHeader().write(to: source)
            let link = root.appendingPathComponent("Link.dylib")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
            XCTAssertThrowsError(try TweakImportSupport.validate(link))
            let bundle = root.appendingPathComponent("Unsafe.bundle", isDirectory: true)
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: bundle.appendingPathComponent("link"), withDestinationURL: root)
            XCTAssertThrowsError(try TweakImportSupport.validate(bundle))
        }
    }

    func testCountsBundleFilesAgainstLimit() throws {
        try withDirectory { root in
            let bundle = root.appendingPathComponent("Resources.bundle", isDirectory: true)
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            for name in ["a", "b"] { try Data(repeating: 0, count: 10).write(to: bundle.appendingPathComponent(name)) }
            XCTAssertNoThrow(try TweakImportSupport.validate(bundle, maximumBytes: 20))
            XCTAssertThrowsError(try TweakImportSupport.validate(bundle, maximumBytes: 19))
        }
    }

    func testStagingCopiesWithoutMovingOriginal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Original.dylib")
        try libraryHeader().write(to: source)
        let staged = try await TweakImportSupport.stage([source])
        defer { TweakImportSupport.discard(staged) }
        XCTAssertEqual(staged.count, 1)
        XCTAssertNotEqual(staged[0], source)
        XCTAssertEqual(try Data(contentsOf: staged[0]), try Data(contentsOf: source))
        TweakImportSupport.discard([source])
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testCancelledStagingDoesNotReturnFiles() async throws {
        let task = Task {
            withUnsafeCurrentTask { current in if let current { current.cancel() } }
            return try await TweakImportSupport.stage([])
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled import must not return staged files")
        } catch is CancellationError { } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testDownloadLimitHandlesKnownAndUnknownLengths() {
        XCTAssertFalse(TweakImportSupport.DownloadLimit.shouldCancel(written: 100, expected: -1, maximum: 100))
        XCTAssertTrue(TweakImportSupport.DownloadLimit.shouldCancel(written: 101, expected: -1, maximum: 100))
        XCTAssertTrue(TweakImportSupport.DownloadLimit.shouldCancel(written: 0, expected: 101, maximum: 100))
        XCTAssertFalse(TweakImportSupport.DownloadLimit.shouldCancel(written: 100, expected: 100, maximum: 100))
        XCTAssertTrue(TweakImportSupport.DownloadLimit.shouldCancel(written: 0, expected: -1, maximum: 0))
    }

    func testRepositoryFilenamesPreserveDependenciesWithoutAllowingPathInjection() {
        XCTAssertEqual(TweakImportSupport.repositoryFilename(for: URL(string: "https://example.com/libHelper.dylib")!), "libHelper.dylib")
        XCTAssertEqual(TweakImportSupport.repositoryFilename(for: URL(string: "https://example.com/download")!), "download.dylib")
        XCTAssertNil(TweakImportSupport.repositoryFilename(for: URL(string: "https://example.com/a%2Fb.dylib")!))
        XCTAssertNil(TweakImportSupport.repositoryFilename(for: URL(string: "https://example.com/a%00b.dylib")!))
    }

    func testBrowserRejectsTraversalAndEscapingSymlinks() throws {
        try withDirectory { root in
            let app = root.appendingPathComponent("App.app", isDirectory: true)
            let frameworks = app.appendingPathComponent("Frameworks", isDirectory: true)
            try FileManager.default.createDirectory(at: frameworks, withIntermediateDirectories: true)
            let outside = root.appendingPathComponent("Secret.dylib")
            try libraryHeader().write(to: outside)
            let inside = frameworks.appendingPathComponent("Local.dylib")
            try libraryHeader().write(to: inside)
            try FileManager.default.createSymbolicLink(at: frameworks.appendingPathComponent("Escape.dylib"), withDestinationURL: outside)
            XCTAssertNotNil(TweakImportSupport.resolvedDylibURL("@rpath/Local.dylib", in: app))
            XCTAssertNil(TweakImportSupport.resolvedDylibURL("@rpath/../../Secret.dylib", in: app))
            XCTAssertNil(TweakImportSupport.resolvedDylibURL("@executable_path/../Secret.dylib", in: app))
            XCTAssertNil(TweakImportSupport.resolvedDylibURL("@rpath/Escape.dylib", in: app))
            XCTAssertNil(TweakImportSupport.resolvedDylibURL("/usr/lib/Library.dylib", in: app))
            XCTAssertNil(TweakImportSupport.resolvedDylibURL("@rpath/Local.dylib\u{0}", in: app))
        }
    }
}
