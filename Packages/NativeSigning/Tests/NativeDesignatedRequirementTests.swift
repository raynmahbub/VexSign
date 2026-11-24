import Foundation
import CryptoKit
import XCTest
@testable import NativeSigningLinkSmoke

/// Deferred synthetic binary policy vectors only. Certificate bytes are not
/// X509/trust proof; no signing, Keychain, Apple calls or execution is performed.
final class NativeDesignatedRequirementTests: XCTestCase {
    private static let bundle = "com.example.fixture"
    private static let certificate = Data("synthetic public certificate bytes".utf8)
    private static func word(_ bytes: Data, _ p: Int) -> Int {
        Int(bytes[p]) << 24 | Int(bytes[p + 1]) << 16 | Int(bytes[p + 2]) << 8 | Int(bytes[p + 3])
    }
    func testCanonicalDesignatedLeafAndIdentifierExpressionVector() throws {
        let blob = try NativeDesignatedRequirement.encode(bundleIdentifier: Self.bundle, certificateDER: Self.certificate)
        try NativeDesignatedRequirement.verify(blob, bundleIdentifier: Self.bundle, certificateDER: Self.certificate)
        XCTAssertEqual(Self.word(blob, 0), 0xfade0c01)
        XCTAssertEqual(Self.word(blob, 4), blob.count)
        XCTAssertEqual(Self.word(blob, 8), 1)
        XCTAssertEqual(Self.word(blob, 12), 3)
        XCTAssertEqual(Self.word(blob, 16), 20)
        XCTAssertEqual(Self.word(blob, 20), 0xfade0c00)
        XCTAssertEqual(Self.word(blob, 24), blob.count - 20)
        XCTAssertEqual(Self.word(blob, 28), 1)
        XCTAssertEqual(Self.word(blob, 32), 6)
        XCTAssertEqual(Self.word(blob, 36), 2)
        XCTAssertEqual(Self.word(blob, 40), Self.bundle.utf8.count)
        let identifierEnd = 44 + Self.bundle.utf8.count
        XCTAssertEqual(Data(blob[44..<identifierEnd]), Data(Self.bundle.utf8))
        let anchor = (identifierEnd + 3) & ~3
        XCTAssertTrue(blob[identifierEnd..<anchor].allSatisfy { $0 == 0 })
        XCTAssertEqual(Self.word(blob, anchor), 4)
        XCTAssertEqual(Self.word(blob, anchor + 4), 0)
        XCTAssertEqual(Self.word(blob, anchor + 8), 20)
        XCTAssertEqual(Data(blob[(anchor + 12)...]), Data(Insecure.SHA1.hash(data: Self.certificate)))
    }
    func testWrongIdentityAndRenewedLeafRequireNewPolicy() throws {
        let original = try NativeDesignatedRequirement.encode(bundleIdentifier: Self.bundle, certificateDER: Self.certificate)
        XCTAssertThrowsError(try NativeDesignatedRequirement.verify(original, bundleIdentifier: "com.example.other", certificateDER: Self.certificate))
        XCTAssertThrowsError(try NativeDesignatedRequirement.verify(original, bundleIdentifier: Self.bundle, certificateDER: Self.certificate + Data([1])))
        let renewed = try NativeDesignatedRequirement.encode(bundleIdentifier: Self.bundle, certificateDER: Self.certificate + Data([1]))
        XCTAssertNotEqual(renewed, original)
    }
    func testEveryByteAndTrailingOrTruncatedExpressionsReject() throws {
        let original = try NativeDesignatedRequirement.encode(bundleIdentifier: Self.bundle, certificateDER: Self.certificate)
        for offset in original.indices {
            var changed = original; changed[offset] ^= 1
            XCTAssertThrowsError(try NativeDesignatedRequirement.verify(changed, bundleIdentifier: Self.bundle, certificateDER: Self.certificate), "byte \(offset)")
        }
        XCTAssertThrowsError(try NativeDesignatedRequirement.verify(original + Data([0]), bundleIdentifier: Self.bundle, certificateDER: Self.certificate))
        for size in [0, 8, 20, 32, original.count - 1] {
            XCTAssertThrowsError(try NativeDesignatedRequirement.verify(Data(original.prefix(size)), bundleIdentifier: Self.bundle, certificateDER: Self.certificate))
        }
    }
    func testIdentifierPaddingIsCanonicalForAllResidues() throws {
        for count in 1...4 {
            let bundle = "com.example." + String(repeating: "a", count: count)
            let blob = try NativeDesignatedRequirement.encode(bundleIdentifier: bundle, certificateDER: Self.certificate)
            XCTAssertEqual(blob.count % 4, 0)
            let start = 44 + bundle.utf8.count; let end = (start + 3) & ~3
            XCTAssertTrue(blob[start..<end].allSatisfy { $0 == 0 })
            try NativeDesignatedRequirement.verify(blob, bundleIdentifier: bundle, certificateDER: Self.certificate)
        }
    }
    func testInvalidAndOversizedPolicyInputsReject() throws {
        for bundle in ["", "*", "com..example", "com.example\n"] {
            XCTAssertThrowsError(try NativeDesignatedRequirement.encode(bundleIdentifier: bundle, certificateDER: Self.certificate))
        }
        XCTAssertThrowsError(try NativeDesignatedRequirement.encode(bundleIdentifier: Self.bundle, certificateDER: Data()))
        XCTAssertThrowsError(try NativeDesignatedRequirement.encode(bundleIdentifier: Self.bundle, certificateDER: Data(repeating: 0, count: 65537)))
    }
}
