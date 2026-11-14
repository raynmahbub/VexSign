import XCTest
import NimbleExtensions

/// Certificate/profile import links arrive from external senders. Their base64
/// must decode without letting a malformed or oversized link allocate unbounded
/// memory or stage a file that the importer would treat as valid.
final class DeepLinkBase64StagingTests: XCTestCase {
    private func staged(_ base64: String, maxBytes: Int = 16 << 20, path: String = ".txt") -> URL? {
        FileManager.default.decodeAndWrite(base64: base64, pathComponent: path, maxBytes: maxBytes)
    }

    func testStandardBase64IsStaged() throws {
        let url = try XCTUnwrap(staged("aGVsbG8="))
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try Data(contentsOf: url), Data("hello".utf8))
    }

    func testMissingPaddingIsAccepted() throws {
        let url = try XCTUnwrap(staged("aGVsbG8"))
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try Data(contentsOf: url), Data("hello".utf8))
    }

    func testWhitespaceIsIgnored() throws {
        let url = try XCTUnwrap(staged("aGVs\n bG8=\t"))
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try Data(contentsOf: url), Data("hello".utf8))
    }

    func testBase64URLAlphabetIsAccepted() throws {
        // Standard base64 of 0xFB 0xFF is "+/8="; base64url is "-_8=".
        let url = try XCTUnwrap(staged("-_8"))
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try Data(contentsOf: url), Data([0xFB, 0xFF]))
    }

    func testOversizedPayloadIsRejected() {
        let payload = Data(repeating: 0x41, count: 128).base64EncodedString()
        XCTAssertNil(staged(payload, maxBytes: 16))
    }

    func testInvalidBase64IsRejected() {
        XCTAssertNil(staged("%%not-base64%%"))
        XCTAssertNil(staged(""))
    }
}
