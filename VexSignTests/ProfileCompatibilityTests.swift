//
//  ProfileCompatibilityTests.swift
//  VexSignTests
//
//  Table-driven tests for. Profiles are built as `Certificate` values in memory — the
//  same decoded shape `CertificateReader` produces from a real `.mobileprovision` — so the
//  whole engine runs without a device and without touching disk.
//

import XCTest
@testable import VexSign

final class ProfileCompatibilityTests: XCTestCase {
	// MARK: - Coverage

	func testExplicitProfileThatNamesThisAppIsCompatible() {
		let evaluation = ProfileCompatibility.evaluate(
			profile: _profile(appIdentifier: "TEAM12345.com.example.app"),
			target: _target("com.example.app")
		)

		XCTAssertEqual(evaluation.verdict, .covers)
		XCTAssertFalse(evaluation.hasBlocking, _describe(evaluation))
	}

	func testWildcardProfileIsReportedAsWildcard() {
		let evaluation = ProfileCompatibility.evaluate(
			profile: _profile(appIdentifier: "TEAM12345.*"),
			target: _target("com.example.app")
		)

		XCTAssertEqual(evaluation.verdict, .wildcard)
		XCTAssertFalse(evaluation.hasBlocking, _describe(evaluation))
	}

	func testExplicitProfileForAnotherAppBlocksAndSuggestsTheIdentifierItCovers() {
		let evaluation = ProfileCompatibility.evaluate(
			profile: _profile(appIdentifier: "TEAM12345.com.example.profile"),
			target: _target("com.example.app")
		)

		XCTAssertEqual(evaluation.verdict, .unusable)
		XCTAssertTrue(evaluation.blockingIssues.contains { $0.code == .appIdentifierMismatch }, _describe(evaluation))
		XCTAssertEqual(
			evaluation.suggestedBundleIdentifier,
			"com.example.profile",
			"the fix is the identifier the profile actually covers"
		)
	}

	func testVerdictTable() {
		let cases: [(pattern: String, bundle: String, verdict: ProfileCompatibility.Verdict)] = [
			("TEAM12345.com.example.app", "com.example.app", .covers),
			("TEAM12345.*", "com.example.app", .wildcard),
			("TEAM12345.com.example.*", "com.example.app", .wildcard),
			("TEAM12345.com.example.*", "com.example.other", .wildcard),
			("TEAM12345.com.example.app", "com.example.other", .unusable),
			("TEAM12345.com.example.app", "com.example.app.extension", .unusable)
		]

		for entry in cases {
			let evaluation = ProfileCompatibility.evaluate(
				profile: _profile(appIdentifier: entry.pattern),
				target: _target(entry.bundle)
			)
			XCTAssertEqual(evaluation.verdict, entry.verdict, "\(entry.pattern) vs \(entry.bundle)")
		}
	}

	// MARK: - Profile state

	func testExpiredProfileBlocks() {
		let evaluation = ProfileCompatibility.evaluate(
			profile: _profile(expiry: Date().addingTimeInterval(-60 * 60 * 24)),
			target: _target("com.example.app")
		)

		XCTAssertEqual(evaluation.verdict, .unusable)
		XCTAssertTrue(evaluation.blockingIssues.contains { $0.code == .profileExpired }, _describe(evaluation))
	}

	func testMissingProfileIsUnknownInsteadOfBlocking() {
		let evaluation = ProfileCompatibility.evaluate(profile: nil, target: _target("com.example.app"))

		XCTAssertEqual(evaluation.verdict, .unknown)
		XCTAssertFalse(evaluation.hasBlocking, "a profile we cannot read is not proof the app will fail")
	}

	// MARK: - Team

	func testProfileFromAnotherTeamBlocks() {
		// The team comes from the entitlements file (see `Target(app:options:)`); the bundle
		// identifier itself carries no team, which is why coverage cannot check it.
		let target = ProfileCompatibility.Target(
			bundleIdentifier: "com.example.app",
			requestedEntitlements: ["application-identifier": "OTHERTEAM.com.example.app"],
			teamIdentifier: "OTHERTEAM"
		)

		let evaluation = ProfileCompatibility.evaluate(
			profile: _profile(appIdentifier: "TEAM12345.com.example.app"),
			target: target
		)

		XCTAssertEqual(evaluation.verdict, .unusable)
		XCTAssertTrue(evaluation.blockingIssues.contains { $0.code == .teamMismatch }, _describe(evaluation))
	}

	// MARK: - Entitlements

	func testRequestedEntitlementTheProfileDoesNotGrantBlocks() {
		let evaluation = ProfileCompatibility.evaluate(
			profile: _profile(),
			target: _target("com.example.app", entitlements: ["aps-environment": "production"])
		)

		XCTAssertEqual(evaluation.verdict, .unusable)
		XCTAssertTrue(evaluation.blockingIssues.contains { $0.code == .entitlementNotGranted }, _describe(evaluation))
	}

	func testRequestedEntitlementTheProfileGrantsPasses() {
		let evaluation = ProfileCompatibility.evaluate(
			profile: _profile(extraEntitlements: ["aps-environment": "production"]),
			target: _target("com.example.app", entitlements: ["aps-environment": "production"])
		)

		XCTAssertFalse(evaluation.hasBlocking, _describe(evaluation))
	}

	func testAppGroupSubsetIsFineButAMissingGroupBlocks() {
		let granted = _profile(extraEntitlements: ["com.apple.security.application-groups": ["group.shared", "group.extra"]])

		let subset = ProfileCompatibility.evaluate(
			profile: granted,
			target: _target("com.example.app", entitlements: [
				"com.apple.security.application-groups": ["group.shared"]
			])
		)
		XCTAssertFalse(subset.hasBlocking, "asking for fewer groups than the profile grants is fine")

		let missing = ProfileCompatibility.evaluate(
			profile: granted,
			target: _target("com.example.app", entitlements: [
				"com.apple.security.application-groups": ["group.other"]
			])
		)
		XCTAssertTrue(missing.blockingIssues.contains { $0.code == .entitlementNotGranted }, _describe(missing))
	}

	func testKeysVexSignRewritesAreNotTreatedAsProblems() {
		// Rewritten by keychain isolation, added for JIT, or derived per team.
		let evaluation = ProfileCompatibility.evaluate(
			profile: _profile(),
			target: _target("com.example.app", entitlements: [
				"keychain-access-groups": ["TEAM12345.com.example.isolated"],
				"dynamic-codesigning": true,
				"com.apple.security.cs.allow-jit": true,
				"get-task-allow": true,
				"com.apple.developer.team-identifier": "TEAM12345"
			])
		)

		XCTAssertFalse(evaluation.hasBlocking, _describe(evaluation))
	}

	// MARK: - Extensions

	func testUncoveredExtensionWarnsButDoesNotBlock() {
		let evaluation = ProfileCompatibility.evaluate(
			profile: _profile(appIdentifier: "TEAM12345.com.example.app"),
			target: _target("com.example.app", nested: ["com.example.app.widget"])
		)

		XCTAssertFalse(evaluation.hasBlocking, "owns the per-extension fix; this must not block")
		XCTAssertTrue(evaluation.issues.contains { $0.code == .extensionNotCovered }, _describe(evaluation))
	}

	func testWildcardProfileCoversExtensions() {
		let evaluation = ProfileCompatibility.evaluate(
			profile: _profile(appIdentifier: "TEAM12345.*"),
			target: _target("com.example.app", nested: ["com.example.app.widget"])
		)

		XCTAssertFalse(evaluation.issues.contains { $0.code == .extensionNotCovered }, _describe(evaluation))
	}

	// MARK: - Certificate

	func testCertificateThatIsNotInTheProfileBlocks() {
		let evaluation = ProfileCompatibility.evaluate(
			profile: _profile(developerCertificates: [Data([0x01, 0x02, 0x03])]),
			leafCertificateDER: Data([0xAA, 0xBB, 0xCC]),
			target: _target("com.example.app")
		)

		XCTAssertEqual(evaluation.verdict, .unusable)
		XCTAssertTrue(evaluation.blockingIssues.contains { $0.code == .certificateNotInProfile }, _describe(evaluation))
	}

	func testCertificateThatIsInTheProfilePasses() {
		let der = Data([0x01, 0x02, 0x03])

		let evaluation = ProfileCompatibility.evaluate(
			profile: _profile(developerCertificates: [Data([0x09]), der]),
			leafCertificateDER: der,
			target: _target("com.example.app")
		)

		XCTAssertFalse(evaluation.hasBlocking, _describe(evaluation))
	}

	func testProfileWithoutAStatedCertificateSkipsTheCheck() {
		let evaluation = ProfileCompatibility.evaluate(
			profile: _profile(developerCertificates: nil),
			leafCertificateDER: Data([0xAA]),
			target: _target("com.example.app")
		)

		XCTAssertFalse(evaluation.hasBlocking, "nothing to compare against is not a failure")
	}

	// MARK: - Devices

	func testDeviceMissingFromTheProfileBlocks() {
		let target = ProfileCompatibility.Target(bundleIdentifier: "com.example.app", deviceUDID: "OTHER-DEVICE")

		let evaluation = ProfileCompatibility.evaluate(
			profile: _profile(devices: ["THIS-DEVICE"]),
			target: target
		)

		XCTAssertTrue(evaluation.blockingIssues.contains { $0.code == .deviceNotProvisioned }, _describe(evaluation))
	}

	func testDeviceInTheProfilePasses() {
		let target = ProfileCompatibility.Target(bundleIdentifier: "com.example.app", deviceUDID: "THIS-DEVICE")

		let evaluation = ProfileCompatibility.evaluate(
			profile: _profile(devices: ["THIS-DEVICE", "ANOTHER"]),
			target: target
		)

		XCTAssertFalse(evaluation.hasBlocking, _describe(evaluation))
	}

	func testInHouseProfileDoesNotCheckTheDeviceList() {
		let target = ProfileCompatibility.Target(bundleIdentifier: "com.example.app", deviceUDID: "ANY-DEVICE")

		let evaluation = ProfileCompatibility.evaluate(
			profile: _profile(devices: nil, allDevices: true),
			target: target
		)

		XCTAssertFalse(evaluation.hasBlocking, _describe(evaluation))
	}

	func testUnknownDeviceSkipsTheCheck() {
		let evaluation = ProfileCompatibility.evaluate(
			profile: _profile(devices: ["THIS-DEVICE"]),
			target: ProfileCompatibility.Target(bundleIdentifier: "com.example.app", deviceUDID: nil)
		)

		XCTAssertFalse(evaluation.hasBlocking, "a jailed app cannot read its own UDID; guessing would block installs")
	}

	// MARK: - Reading

	func testTeamIdentifierIsReadFromEntitlements() {
		XCTAssertEqual(
			ProfileCompatibility.teamIdentifier(in: ["application-identifier": "TEAM12345.com.example.app"]),
			"TEAM12345"
		)
		XCTAssertNil(ProfileCompatibility.teamIdentifier(in: [:]))
	}

	// MARK: - Fixtures

	private func _describe(_ evaluation: ProfileCompatibility.Evaluation) -> String {
		"verdict: \(evaluation.verdict) issues: " +
			evaluation.issues.map { "\($0.code.rawValue)[\($0.severity)]" }.joined(separator: ", ")
	}

	private func _target(
		_ bundleIdentifier: String,
		entitlements: [String: Any] = [:],
		nested: [String] = []
	) -> ProfileCompatibility.Target {
		ProfileCompatibility.Target(
			bundleIdentifier: bundleIdentifier,
			nestedBundleIdentifiers: nested,
			requestedEntitlements: entitlements
		)
	}

	private func _profile(
		appIdentifier: String = "TEAM12345.*",
		extraEntitlements: [String: Any] = [:],
		team: String = "TEAM12345",
		expiry: Date = Date().addingTimeInterval(60 * 60 * 24 * 30),
		devices: [String]? = nil,
		allDevices: Bool = false,
		developerCertificates: [Data]? = nil
	) -> Certificate {
		var entitlements: [String: Any] = extraEntitlements
		entitlements["application-identifier"] = appIdentifier

		return Certificate(
			AppIDName: "Fixture",
			ApplicationIdentifierPrefix: [team],
			CreationDate: Date().addingTimeInterval(-60 * 60 * 24),
			Platform: ["iOS"],
			IsXcodeManaged: nil,
			DeveloperCertificates: developerCertificates,
			derEncodedProfile: nil,
			PPQCheck: nil,
			Entitlements: entitlements.mapValues { AnyCodable($0) },
			ExpirationDate: expiry,
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
