import Foundation
import XCTest
@testable import VexSign

final class ARArchiveSafetyTests: XCTestCase {
    private func member(_ name: String, body: Data = Data([42]), sizeField: String? = nil) -> Data {
        func field(_ value: String, _ width: Int) -> String {
            precondition(value.utf8.count <= width)
            return value + String(repeating: " ", count: width - value.utf8.count)
        }
        let header = field(name, 16) + field("0", 12) + field("0", 6) + field("0", 6)
            + field("100644", 8) + field(sizeField ?? String(body.count), 10) + "`\n"
        var result = Data(header.utf8) + body
        if body.count % 2 != 0 { result.append(10) }
        return result
    }

    private func read(_ members: [Data]) async throws -> [ARFileModel] {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        var archive = Data("!<arch>\n".utf8)
        for entry in members { archive.append(entry) }
        try archive.write(to: file)
        return try await AR(with: file).extract()
    }

    private func assertRejected(_ members: [Data], file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await read(members)
            XCTFail("Unsafe or malformed archive accepted", file: file, line: line)
        } catch is ARError {
            // Expected parser rejection.
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    func testOrdinaryDebNamesAndArTerminator() async throws {
        let entries = try await read([member("debian-binary"), member("control.tar.gz/"), member("data.tar.xz/")])
        XCTAssertEqual(entries.map(\.name), ["debian-binary", "control.tar.gz", "data.tar.xz"])
        XCTAssertEqual(entries.map(\.content), [Data([42]), Data([42]), Data([42])])
    }

    func testTraversalAndInvalidNamesAreRejected() async {
        for name in ["../escape", "../../outside", "/tmp/escape", ".", "..", "nested/file", "bad\\file", "bad\0file", "//"] {
            await assertRejected([member(name)])
        }
    }

    func testDuplicateNamesAndTruncatedMemberAreRejected() async {
        await assertRejected([member("data.tar.xz"), member("DATA.TAR.XZ/")])
        await assertRejected([member("data.tar.xz", sizeField: "9999999999")])
    }
}
