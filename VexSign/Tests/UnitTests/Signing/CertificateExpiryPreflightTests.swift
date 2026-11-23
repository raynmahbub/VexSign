//
//  CertificateExpiryPreflightTests.swift
//  VexSignTests
//
//  The two certificate-expiry findings are one comparison apart, and until now they were also
//  one code apart from the truth: "expired" is blocking and "expires in three days" is a
//  warning, but both were emitted with `code: .certificateExpired`. The code is the stable key
//  a log line, a test or a future consumer reads (`SigningCapability.Issue.Code` documents it as
//  "asserted by tests and written to the signing log"), so the advisory finding claimed the
//  blocking one's identity.
//
//  `PreflightChecks.expiryIssues(expiration:now:)` is the two findings as a pure function, which
//  is what makes them testable without a Keychain-backed `CertificatePair`.
//

import XCTest
@testable import VexSign

@MainActor
final class CertificateExpiryPreflightTests: XCTestCase {

	private let now = Date(timeIntervalSince1970: 1_800_000_000)
	private let day: TimeInterval = 24 * 3600

	func testAnExpiredCertificateIsBlockingAndNamesTheExpiry() throws {
		let issues = PreflightChecks.expiryIssues(expiration: now.addingTimeInterval(-day), now: now)
		let issue = try XCTUnwrap(issues.first)
		XCTAssertEqual(issues.count, 1)
		XCTAssertEqual(issue.severity, .blocking)
		XCTAssertEqual(issue.code, .certificateExpired)
		XCTAssertEqual(issue.status, .expired)
		XCTAssertTrue(issue.isMandatory)
		XCTAssertNotNil(issue.remediation)
	}

	func testACertificateInsideTheWarningWindowIsAdvisoryUnderItsOwnCode() throws {
		let issues = PreflightChecks.expiryIssues(expiration: now.addingTimeInterval(3 * day), now: now)
		let issue = try XCTUnwrap(issues.first)
		XCTAssertEqual(issues.count, 1)
		XCTAssertEqual(issue.severity, .warning)
		XCTAssertEqual(issue.code, .certificateExpiringSoon)
		XCTAssertEqual(issue.status, .requiresAction)
		// The whole point: a warning no longer carries a code that means "expired".
		XCTAssertFalse(issue.code.isMandatory)
		XCTAssertFalse(issue.isMandatory)
		XCTAssertNotNil(issue.remediation)
	}

	func testACertificatePastTheWindowProducesNothing() {
		XCTAssertTrue(PreflightChecks.expiryIssues(expiration: now.addingTimeInterval(30 * day), now: now).isEmpty)
	}

	func testTheWindowBoundaryIsExclusive() {
		// At exactly seven days the certificate still has a week: no warning yet.
		XCTAssertTrue(PreflightChecks.expiryIssues(expiration: now.addingTimeInterval(7 * day), now: now).isEmpty)
		XCTAssertEqual(PreflightChecks.expiryIssues(expiration: now.addingTimeInterval(7 * day - 1), now: now).count, 1)
	}

	func testEveryCodeInTheCatalogueStillClassifies() {
		// `Code` is `CaseIterable`, so a new case has to survive the sweep a test can do over it.
		for code in SigningCapability.Issue.Code.allCases {
			XCTAssertFalse(code.rawValue.isEmpty)
			// A mandatory code is what the preflight sheet refuses to override, so it may only
			// belong to findings that are blocking by construction.
			if code.isMandatory {
				XCTAssertTrue(
					[.certificateMissing, .certificateExpired, .certificateRevoked,
					 .certificatePasswordUnavailable, .certificateNotInProfile, .profileMissing,
					 .profileExpired, .profileUnreadable, .teamMismatch, .appIdentifierMismatch,
					 .extensionNotCovered, .entitlementNotGranted, .deviceNotProvisioned,
					 .bundleIdentifierMissing, .infoPlistUnreadable, .executableUnavailable,
					 .executableUnsupportedPlatform, .executableEncrypted, .executablePlatformUnknown,
					 .nestedComponentInvalid, .storageInsufficient, .minimumOSNewerThanDevice].contains(code),
					"\(code.rawValue) is marked mandatory but is not one of the install-time requirements"
				)
			}
		}
	}
}
