import Foundation
import XCTest

/// Source-wiring assertions run against a checkout, not a guessed number of
/// parent directories. A packaged test without its source checkout may skip;
/// a missing/moved source inside an available checkout must fail the test.
enum RepositorySourceFixture {
    static func url(_ relativePath: String, file: StaticString = #filePath) throws -> URL {
        var directory = URL(fileURLWithPath: String(describing: file)).deletingLastPathComponent()
        while directory.path != "/" {
            let project = directory.appendingPathComponent("VexSign.xcodeproj/project.pbxproj")
            if FileManager.default.fileExists(atPath: project.path) {
                return directory.appendingPathComponent(relativePath)
            }
            directory.deleteLastPathComponent()
        }
        throw XCTSkip("Source checkout is not available to this test bundle.")
    }

    static func read(_ relativePath: String, file: StaticString = #filePath) throws -> String {
        try String(contentsOf: url(relativePath, file: file), encoding: .utf8)
    }
}
