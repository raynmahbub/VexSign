//
//  LogRedactionTests.swift
//  VexSignTests
//
//  Tests for the log a user can export must not contain their secrets.
//
//  Every rule is asserted in both directions — what it must mask, and what it must leave alone.
//  A redaction rule that over-fires is worse than none: it hides the reason a sign failed.
//

import Foundation
import XCTest
@testable import VexSign

final class LogRedactionTests: XCTestCase {
	private func assertRedacted(
		_ input: String,
		_ secret: String,
		file: StaticString = #filePath,
		line: UInt = #line
	) {
		let output = LogRedaction.redact(input)
		XCTAssertFalse(output.contains(secret), "\(secret) survived redaction: \(output)", file: file, line: line)
		XCTAssertTrue(output.contains(LogRedaction.marker), "nothing was masked in: \(output)", file: file, line: line)
	}

    func testPrivateKeysPairingMaterialAndCookiesAreRedacted() {
        assertRedacted("-----BEGIN RSA PRIVATE KEY-----\nprivate-bytes\n-----END RSA PRIVATE KEY-----", "private-bytes")
        assertRedacted("<key>HostPrivateKey</key>\n<data>pairing-bytes</data>", "pairing-bytes")
        assertRedacted("Cookie: session=private-session; other=private-cookie", "private-session")
        assertRedacted("Set-Cookie: session=private-session", "private-session")
        XCTAssertEqual(LogRedaction.redact("Install failed at verifying"), "Install failed at verifying")
    }

	// MARK: - What must be masked

	func testPasswordAssignmentsAreMasked() {
		assertRedacted("p12Password=hunter2", "hunter2")
		assertRedacted("password: hunter2", "hunter2")
		assertRedacted("password=\"hun ter\"", "hun ter")
	}

	func testTokensAndKeysAreMasked() {
		assertRedacted("token=abc123def456", "abc123def456")
		assertRedacted("api_key=sk-live-1234", "sk-live-1234")
		assertRedacted("X-API-Key: sk-live-1234", "sk-live-1234")
		assertRedacted("secret=topsecret", "topsecret")
	}

	func testBearerTokensAreMasked() {
		assertRedacted("Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.payload.sig", "eyJhbGciOiJIUzI1NiJ9")
		assertRedacted("sent Bearer abcdef123456 upstream", "abcdef123456")
	}

	func testAnAuthorizationSchemeWithoutTheBearerWordIsMaskedToo() {
		assertRedacted("authorization: Basic dXNlcjpwYXNz", "dXNlcjpwYXNz")
	}

	func testPasswordInsideAURLIsMaskedButTheHostSurvives() {
		let output = LogRedaction.redact("fetching https://alice:s3cret@example.com/repo.json")
		XCTAssertFalse(output.contains("s3cret"))
		XCTAssertTrue(output.contains("example.com/repo.json"), "the host is the useful part: \(output)")
	}

	// MARK: - What must be left alone

	func testAnOrdinaryLogLineIsUntouched() {
		let line = "Signed Example.app (com.example.app) 2.1.0 from https://example.com/repo.json in 4.2s"
		XCTAssertEqual(LogRedaction.redact(line), line)
	}

	/// A word that merely contains one of the keys is not a key.
	func testWordsThatOnlyContainAKeywordAreUntouched() {
		let line = "tokenised the entitlements and re-sealed the bundle"
		XCTAssertEqual(LogRedaction.redact(line), line)
	}

	func testAURLWithoutCredentialsIsUntouched() {
		let line = "GET https://cdn.example.com/app.ipa"
		XCTAssertEqual(LogRedaction.redact(line), line)
	}

	func testEmptyInputStaysEmpty() {
		XCTAssertEqual(LogRedaction.redact(""), "")
	}

	// MARK: - Shape

	func testRedactionIsIdempotent() {
		let once = LogRedaction.redact("password=hunter2 and token=abc123")
		XCTAssertEqual(LogRedaction.redact(once), once)
	}

	/// Several secrets on one line are all masked, not just the first match.
	func testEveryOccurrenceOnALineIsMasked() {
		let output = LogRedaction.redact("first password=one then password=two")
		XCTAssertFalse(output.contains("one "))
		XCTAssertFalse(output.contains("two"))
	}
}
