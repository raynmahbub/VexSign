//
//  ProfileApplicationIdentifierMatcherTests.swift
//  VexSignTests
//
//  The one rule for whether a profile's App ID authorizes a bundle identifier, and what
//  "Sign Anyway" may and may not excuse once that rule has said no.
//
//  The reported case is kept literally: an app `streaming.octave.dev` with a widget
//  `streaming.octave.dev.OctaveWidgets`, and a profile whose App ID is the explicit
//  `N2998T85B9.app.vanilla7419.emerald5335`. The profile includes neither bundle.
//

import XCTest
@testable import VexSign

final class ProfileApplicationIdentifierMatcherTests: XCTestCase {
	private typealias Matcher = ProfileApplicationIdentifierMatcher

	private let reportedProfile = "N2998T85B9.app.vanilla7419.emerald5335"
	private let reportedApp = "streaming.octave.dev"
	private let reportedWidget = "streaming.octave.dev.OctaveWidgets"

	// MARK: - Parsing

	func testAnExplicitAppIDSplitsIntoPrefixAndIdentifier() throws {
		let parsed = try Matcher.parse(reportedProfile).get()
		XCTAssertEqual(parsed.prefix, "N2998T85B9")
		XCTAssertEqual(parsed.pattern, "app.vanilla7419.emerald5335")
		XCTAssertFalse(parsed.isWildcard)
		XCTAssertNil(parsed.wildcardStem)
		XCTAssertTrue(parsed.hasStandardPrefixLength)
	}

	func testWildcardsAreRecognisedOnlyAsAWholeLastComponent() throws {
		XCTAssertEqual(try Matcher.parse("ABCDE12345.*").get().wildcardStem, "")
		XCTAssertEqual(try Matcher.parse("ABCDE12345.com.example.*").get().wildcardStem, "com.example.")
	}

	func testMalformedAppIDsAreRejectedWithAReason() {
		let cases: [(String, Matcher.Malformation)] = [
			("", .empty),
			("   ", .empty),
			("ABCDE12345", .missingPrefix),
			(".com.example.app", .invalidPrefix),
			("AB-DE.com.example.app", .invalidPrefix),
			("ABCDE12345.", .emptyPattern),
			("ABCDE12345.com.example*", .misplacedWildcard),
			("ABCDE12345.com.*.app", .misplacedWildcard),
			("ABCDE12345.*.*", .misplacedWildcard),
			("ABCDE12345.com.**", .misplacedWildcard),
			("ABCDE12345.com..app", .invalidCharacters),
			("ABCDE12345.com.exa mple", .invalidCharacters)
		]
		for (value, expected) in cases {
			guard case .failure(let reason) = Matcher.parse(value) else {
				XCTFail("\(value) should not parse")
				continue
			}
			XCTAssertEqual(reason, expected, value)
		}
	}

	// MARK: - Matching

	func testAnExplicitAppIDAuthorizesOnlyItsOwnIdentifier() {
		let profile = "ABCDE12345.com.example.app"
		XCTAssertEqual(Matcher.match(applicationIdentifier: profile, bundleIdentifier: "com.example.app").outcome, .exact)
		for other in ["com.example.app.widget", "com.example.ap", "com.example.app2", "com.example", "COM.example.app"] {
			XCTAssertEqual(
				Matcher.match(applicationIdentifier: profile, bundleIdentifier: other).outcome, .notAuthorized, other
			)
		}
	}

	func testAWildcardNeedsTheWholeStemAndAtLeastOneMoreCharacter() {
		let profile = "ABCDE12345.com.example.*"
		XCTAssertEqual(Matcher.match(applicationIdentifier: profile, bundleIdentifier: "com.example.app").outcome, .wildcard)
		XCTAssertEqual(Matcher.match(applicationIdentifier: profile, bundleIdentifier: "com.example.app.widget").outcome, .wildcard)

		// A raw prefix comparison without the separator would accept this one.
		XCTAssertEqual(Matcher.match(applicationIdentifier: profile, bundleIdentifier: "com.examplex.app").outcome, .notAuthorized)
		// The stem alone is not included, and neither is the stem with nothing after it.
		XCTAssertEqual(Matcher.match(applicationIdentifier: profile, bundleIdentifier: "com.example").outcome, .notAuthorized)
		XCTAssertEqual(Matcher.match(applicationIdentifier: profile, bundleIdentifier: "com.example.").outcome, .malformedIdentifier)
	}

	func testTheFullWildcardAuthorizesAnyWellFormedIdentifier() {
		XCTAssertEqual(Matcher.match(applicationIdentifier: "ABCDE12345.*", bundleIdentifier: reportedApp).outcome, .wildcard)
		XCTAssertEqual(Matcher.match(applicationIdentifier: "ABCDE12345.*", bundleIdentifier: reportedWidget).outcome, .wildcard)
		XCTAssertEqual(Matcher.match(applicationIdentifier: "ABCDE12345.*", bundleIdentifier: "").outcome, .malformedIdentifier)
	}

	func testAMalformedProfileAuthorizesNothing() {
		let match = Matcher.match(applicationIdentifier: "ABCDE12345.com.example*", bundleIdentifier: "com.example.app")
		XCTAssertEqual(match.outcome, .malformedProfile(.misplacedWildcard))
		XCTAssertFalse(match.isAuthorized)
		XCTAssertNil(match.authorized)
	}

	func testTheAppIDPrefixIsComparedOnlyWhereAPrefixIsPresent() {
		// A bundle identifier has no prefix, so the profile's prefix plays no part.
		XCTAssertTrue(Matcher.match(applicationIdentifier: "ABCDE12345.com.example.app", bundleIdentifier: "com.example.app").isAuthorized)
		// A signed entitlement value has one, and it must be the same.
		XCTAssertEqual(
			Matcher.match(applicationIdentifier: "ABCDE12345.com.example.*", entitlementValue: "ABCDE12345.com.example.app").outcome,
			.wildcard
		)
		XCTAssertEqual(
			Matcher.match(applicationIdentifier: "ABCDE12345.com.example.*", entitlementValue: "ZZZZZ99999.com.example.app").outcome,
			.prefixMismatch
		)
	}

	// MARK: - The reported case

	func testTheReportedProfileAuthorizesNeitherTheAppNorItsWidget() {
		let app = Matcher.match(applicationIdentifier: reportedProfile, bundleIdentifier: reportedApp)
		let widget = Matcher.match(applicationIdentifier: reportedProfile, bundleIdentifier: reportedWidget)

		XCTAssertEqual(app.outcome, .notAuthorized)
		XCTAssertEqual(widget.outcome, .notAuthorized)
		XCTAssertEqual(app.authorized?.pattern, "app.vanilla7419.emerald5335")

		// The entry points the rest of the app uses give the same answer.
		XCTAssertFalse(SignatureVerifier.coverage(of: reportedProfile, includes: reportedApp))
		XCTAssertFalse(SignatureVerifier.coverage(of: reportedProfile, includes: reportedWidget))
		XCTAssertFalse(SignatureVerifier.isWildcard(reportedProfile))
	}

	func testTheReportedProfileAuthorizesTheIdentifierItNames() {
		XCTAssertEqual(
			Matcher.match(applicationIdentifier: reportedProfile, bundleIdentifier: "app.vanilla7419.emerald5335").outcome,
			.exact
		)
	}

	func testCoverageRejectsWhatTheOldPrefixRuleAccepted() {
		// `com.example*` used to be read as "starts with com.example".
		XCTAssertFalse(SignatureVerifier.coverage(of: "TEAM.com.example*", includes: "com.example.app"))
		XCTAssertFalse(SignatureVerifier.isWildcard("TEAM.com.example*"))
		// An identifier with an empty component is not included by any wildcard.
		XCTAssertFalse(SignatureVerifier.coverage(of: "TEAM.*", includes: "com..app"))
	}

	// MARK: - What "Sign Anyway" may excuse

	private func _issue(_ code: SigningCapability.Issue.Code, blocking: Bool = true) -> PreflightIssue {
		PreflightIssue("t-\(code.rawValue)", "d", severity: blocking ? .blocking : .warning, code: code)
	}

	func testRequirementsEnforcedAtInstallAreNotOfferedSignAnyway() {
		let mandatory: [SigningCapability.Issue.Code] = [
			.certificateMissing, .certificateExpired, .certificateRevoked, .profileExpired,
			.appIdentifierMismatch, .extensionNotCovered, .entitlementNotGranted
		]
		for code in mandatory {
			let result = PreflightResult(issues: [_issue(code)])
			XCTAssertTrue(result.hasBlocking, code.rawValue)
			XCTAssertTrue(result.hasMandatoryFailure, code.rawValue)
			XCTAssertFalse(result.canSignAnyway, code.rawValue)
		}
	}

	func testOtherBlockingFindingsCanStillBeAccepted() {
		let acceptable: [SigningCapability.Issue.Code] = [
			.teamMismatch, .certificateNotInProfile, .deviceNotProvisioned, .signerMismatch,
			.storageInsufficient, .general
		]
		for code in acceptable {
			let result = PreflightResult(issues: [_issue(code)])
			XCTAssertFalse(result.hasMandatoryFailure, code.rawValue)
			XCTAssertTrue(result.canSignAnyway, code.rawValue)
		}
	}

	func testAnAdvisoryWithAMandatoryCodeDoesNotBlock() {
		// An extension that compatibility mode will remove is reported as a warning.
		let result = PreflightResult(issues: [_issue(.extensionNotCovered, blocking: false)])
		XCTAssertFalse(result.hasBlocking)
		XCTAssertFalse(result.hasMandatoryFailure)
		XCTAssertFalse(result.canSignAnyway)
	}

	func testOneMandatoryFailureWithdrawsSignAnywayForTheWholeReview() {
		let result = PreflightResult(issues: [_issue(.teamMismatch), _issue(.appIdentifierMismatch)])
		XCTAssertTrue(result.hasMandatoryFailure)
		XCTAssertFalse(result.canSignAnyway)
	}

	func testTheCapabilityReportRefusesOnlyMandatoryFailures() {
		func capability(_ codes: [(SigningCapability.Issue.Code, SigningCapability.Severity)]) -> SigningCapability {
			SigningCapability(issues: codes.map {
				SigningCapability.Issue(
					code: $0.0, severity: $0.1, status: .incompatible, title: "t", detail: "detail-\($0.0.rawValue)", remediation: nil
				)
			})
		}

		XCTAssertNil(capability([]).refusal)
		XCTAssertNil(capability([(.teamMismatch, .blocking)]).refusal)
		XCTAssertNil(capability([(.appIdentifierMismatch, .advisory)]).refusal)

		let refusal = capability([(.teamMismatch, .blocking), (.appIdentifierMismatch, .blocking), (.extensionNotCovered, .blocking)]).refusal
		XCTAssertEqual(refusal?.codes, [.appIdentifierMismatch, .extensionNotCovered])
		XCTAssertTrue(refusal?.localizedDescription.contains("detail-\(SigningCapability.Issue.Code.appIdentifierMismatch.rawValue)") == true)
	}

	// MARK: - The reported case, end to end through the profile evaluation

	func testTheReportedCaseIsAMandatoryFailureForBothBundles() {
		let evaluation = ProfileCompatibility.evaluate(
			profile: _profile(appIdentifier: reportedProfile, team: "N2998T85B9"),
			target: ProfileCompatibility.Target(
				bundleIdentifier: reportedApp,
				nestedBundleIdentifiers: [reportedWidget],
				requestedEntitlements: [:]
			)
		)

		XCTAssertEqual(evaluation.verdict, .unusable)
		let blocking = Set(evaluation.issues.filter(\.isBlocking).map(\.code))
		XCTAssertTrue(blocking.contains(.appIdentifierMismatch))
		XCTAssertTrue(blocking.contains(.extensionNotCovered))
	}

	func testAMalformedProfileAppIDIsReportedAsSuchWithNoSuggestion() {
		let evaluation = ProfileCompatibility.evaluate(
			profile: _profile(appIdentifier: "ABCDE12345.com.example*", team: "ABCDE12345"),
			target: ProfileCompatibility.Target(
				bundleIdentifier: "com.example.app", nestedBundleIdentifiers: [], requestedEntitlements: [:]
			)
		)
		XCTAssertEqual(evaluation.verdict, .unusable)
		XCTAssertNil(evaluation.suggestedBundleIdentifier)
		XCTAssertTrue(evaluation.issues.contains { $0.code == .appIdentifierMismatch && $0.isBlocking })
	}

	// MARK: - App ID prefix and Team ID

	func testAnAppIDPrefixThatDiffersFromTheTeamIDIsNotATeamMismatch() {
		// An App ID created under an older account keeps its own prefix.
		XCTAssertTrue(ProfileCompatibility.prefixBelongsToProfile(
			"OLDPREFIX1", teamIdentifiers: ["TEAM123456"], applicationIdentifierPrefixes: ["OLDPREFIX1"]
		))
		XCTAssertTrue(ProfileCompatibility.prefixBelongsToProfile(
			"TEAM123456", teamIdentifiers: ["TEAM123456"], applicationIdentifierPrefixes: ["OLDPREFIX1"]
		))
		XCTAssertFalse(ProfileCompatibility.prefixBelongsToProfile(
			"OTHERTEAM1", teamIdentifiers: ["TEAM123456"], applicationIdentifierPrefixes: ["OLDPREFIX1"]
		))
		XCTAssertFalse(ProfileCompatibility.prefixBelongsToProfile("X", teamIdentifiers: [], applicationIdentifierPrefixes: []))
	}

	// MARK: - Profile type

	func testAnAppStoreStyleProfileIsFlaggedWithoutBlocking() {
		func evaluate(allDevices: Bool, devices: [String]?) -> ProfileCompatibility.Evaluation {
			ProfileCompatibility.evaluate(
				profile: _profile(appIdentifier: "ABCDE12345.*", team: "ABCDE12345", allDevices: allDevices, devices: devices),
				target: ProfileCompatibility.Target(
					bundleIdentifier: "com.example.app", nestedBundleIdentifiers: [], requestedEntitlements: [:]
				)
			)
		}

		let appStore = evaluate(allDevices: false, devices: nil)
		XCTAssertTrue(appStore.issues.contains { $0.code == .deviceNotProvisioned && !$0.isBlocking })
		XCTAssertFalse(appStore.hasBlocking)
		XCTAssertEqual(appStore.verdict, .wildcard)

		XCTAssertFalse(evaluate(allDevices: true, devices: nil).issues.contains { $0.code == .deviceNotProvisioned })
		XCTAssertFalse(evaluate(allDevices: false, devices: ["00008030-TEST"]).issues.contains { $0.code == .deviceNotProvisioned })
	}

	// MARK: - Fixtures

	private func _profile(
		appIdentifier: String, team: String, allDevices: Bool = true, devices: [String]? = nil
	) -> Certificate {
		Certificate(
			AppIDName: "Fixture",
			ApplicationIdentifierPrefix: [team],
			CreationDate: Date().addingTimeInterval(-60 * 60 * 24),
			Platform: ["iOS"],
			IsXcodeManaged: nil,
			DeveloperCertificates: nil,
			derEncodedProfile: nil,
			PPQCheck: nil,
			Entitlements: ["application-identifier": AnyCodable(appIdentifier)],
			ExpirationDate: Date().addingTimeInterval(60 * 60 * 24 * 30),
			Name: "Fixture Profile",
			ProvisionsAllDevices: allDevices,
			ProvisionedDevices: devices,
			TeamIdentifier: [team],
			TeamName: "Fixture Team",
			TimeToLive: 365,
			UUID: "FIXTURE-PROFILE",
			Version: 1
		)
	}
}
