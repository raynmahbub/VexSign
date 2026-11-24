import Foundation
import XCTest
import SideSign

/// Covers SideSign's own pure, dependency-free helpers: the deterministic API the app links
/// directly but the synthesized native-signing-smoke harness (which tests VexSign's codec
/// wrappers) never exercises on its own terms. Every case here is pure — no device, network
/// account, signing identity or external ASN.1 decoder — so the target builds and runs anywhere
/// `swift test` can resolve the pinned dependencies.
final class SideSignPureTests: XCTestCase {
    func testExtractDERPassesNonPEMBytesThroughUnchanged() {
        // Without a "-----BEGIN " marker the input is treated as already-DER and returned
        // byte-for-byte. Non-UTF-8 bytes short-circuit the same way, since the PEM check
        // needs a String first. (The PEM-decode branch defers to a dependency's decoder and
        // is intentionally not asserted here.)
        let der = Data([0x30, 0x82, 0x00, 0x01, 0x00])
        XCTAssertEqual(CertificateParser.extractDER(der), der)

        let text = Data("not a PEM block".utf8)
        XCTAssertEqual(CertificateParser.extractDER(text), text)
    }

    func testSanitizeBundleIDKeepsOnlyLegalCharactersAndTrimsEdges() {
        XCTAssertEqual(InfoPlistParser.sanitizeBundleID("com.example.app"), "com.example.app")
        XCTAssertEqual(InfoPlistParser.sanitizeBundleID("com..example"), "com.example", "runs of dots collapse to one")
        XCTAssertEqual(InfoPlistParser.sanitizeBundleID(".leading.and.trailing-"), "leading.and.trailing", "edge dots and dashes trim")
        XCTAssertEqual(InfoPlistParser.sanitizeBundleID("a/b c@d"), "abcd", "characters outside [A-Za-z0-9.-] are dropped")
        XCTAssertEqual(InfoPlistParser.sanitizeBundleID("---"), "", "a name of only separators sanitizes to empty")
    }

    func testSanitizeHeadersRedactsSecretsButKeepsTheLastFour() {
        let headers = [
            "Authorization": "Bearer supersecrettoken",
            "X-Apple-Session-Token": "abcd1234",
            "Cookie": "session=xyz",
            "Accept": "application/json",
        ]
        let sanitized = sanitizeHeadersForLogging(headers)
        // A non-sensitive header is passed through untouched.
        XCTAssertEqual(sanitized["Accept"], "application/json")
        // Sensitive headers are masked to eight bullets plus the last four characters, matching
        // by lowercased key so mixed case still redacts. The point is that the secret itself
        // never reaches a log.
        XCTAssertEqual(sanitized["Authorization"], "••••••••oken")
        XCTAssertEqual(sanitized["X-Apple-Session-Token"], "••••••••1234")
        XCTAssertEqual(sanitized["Cookie"], "••••••••=xyz")
    }
}
