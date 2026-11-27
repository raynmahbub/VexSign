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

    func testStagedPrivateKeyPayloadIsOwnerOnly() throws {
        let url = try XCTUnwrap(staged("aGVsbG8="))
        defer { try? FileManager.default.removeItem(at: url) }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, 0o600)
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

    /// The cap must be applied to the *encoded* text, before whitespace filtering, the
    /// base64url substitutions and the decode allocate copies of the payload. A payload
    /// many times the limit stands in for the hostile link this guards against.
    func testGrosslyOversizedPayloadIsRejectedWithoutDecoding() {
        let payload = String(repeating: "A", count: 8 << 20)
        XCTAssertNil(staged(payload, maxBytes: 16))
    }

    func testPayloadAtTheLimitIsAcceptedAndOneByteOverIsRejected() throws {
        let exact = Data(repeating: 0x41, count: 32)
        let accepted = try XCTUnwrap(staged(exact.base64EncodedString(), maxBytes: 32))
        defer { try? FileManager.default.removeItem(at: accepted) }
        XCTAssertEqual(try Data(contentsOf: accepted), exact)

        let over = Data(repeating: 0x41, count: 33)
        XCTAssertNil(staged(over.base64EncodedString(), maxBytes: 32))
    }

    func testLineWrappedLinkIsStillAccepted() throws {
        // Senders wrap certificate links at 64 characters; the whitespace slack in the
        // encoded-length guard must not turn a legitimate link into a rejection.
        let body = Data(repeating: 0x42, count: 4_096).base64EncodedString()
        let wrapped = stride(from: 0, to: body.count, by: 64).map { offset -> String in
            let start = body.index(body.startIndex, offsetBy: offset)
            let end = body.index(start, offsetBy: min(64, body.count - offset))
            return String(body[start..<end])
        }.joined(separator: "\n")
        let url = try XCTUnwrap(staged(wrapped, maxBytes: 4_096))
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try Data(contentsOf: url).count, 4_096)
    }

    func testInvalidBase64IsRejected() {
        XCTAssertNil(staged("%%not-base64%%"))
        XCTAssertNil(staged(""))
    }
}
