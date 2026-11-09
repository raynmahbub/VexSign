//
//  ExtensionSigningRegressionTests.swift
//  VexSignTests
//
//  Regression tests for #137 ("certificate extension"): a certificate that signs app
//  extensions in other signers stopped doing so in VexSign.
//
//  Three separate defects produced that, and each is pinned here:
//
//   1. The preflight judged extensions by the identifier they had *before* the bundle-id
//      rewrite. Both `SigningHandler._modifyPluginIdentifiers` and the pinned engine
//      (`ZBundle::ModifyPluginsBundleId`) replace the old app id with the new one inside every
//      nested bundle, so a profile covering the new id covers the renamed extensions too.
//   2. "Sign Anyway" was offered by the preflight sheet and honoured by the post-sign
//      verifier, but the nested-bundle audit threw regardless — so the override did nothing.
//   3. The one-time options migration forced compatibility mode (which *deletes* extensions)
//      back on over a saved "off".
//
//  Everything here is in-memory: no device, no signing, no filesystem.
//

import Foundation
import XCTest
@testable import VexSign

final class ExtensionSigningRegressionTests: XCTestCase {
	// MARK: - 1. Coverage is judged after the rewrite

	func testRewriteMirrorsTheEngine() {
		// ZUtil::StringReplace replaces every occurrence of the old base, not just a prefix.
		XCTAssertEqual(
			NestedBundleAudit.rewrittenIdentifier("com.vendor.app.widget", from: "com.vendor.app", to: "com.me.app"),
			"com.me.app.widget"
		)
		XCTAssertEqual(
			NestedBundleAudit.rewrittenIdentifier("com.vendor.app.a.com.vendor.app", from: "com.vendor.app", to: "x"),
			"x.a.x"
		)
	}

	func testRewriteIsANoOpWithoutARealChange() {
		for pair: (String?, String?) in [(nil, "com.me.app"), ("com.vendor.app", nil), ("", "com.me.app"),
										 ("com.vendor.app", ""), ("same", "same")] {
			XCTAssertEqual(
				NestedBundleAudit.rewrittenIdentifier("com.vendor.app.widget", from: pair.0, to: pair.1),
				"com.vendor.app.widget"
			)
		}
	}

	func testAnExtensionUnrelatedToTheAppIdentifierIsLeftAlone() {
		XCTAssertEqual(
			NestedBundleAudit.rewrittenIdentifier("com.other.thing", from: "com.vendor.app", to: "com.me.app"),
			"com.other.thing",
			"the engine only replaces occurrences of the old base; an unrelated id stays uncovered"
		)
	}

	func testPreflightCoversExtensionsThatTheRenameBringsUnderTheProfile() {
		// The #137 case: a prefix-wildcard profile for the *new* identifier. Before the fix
		// the extension was compared as `com.vendor.app.widget` and reported as blocking.
		let evaluation = ProfileCompatibility.evaluate(
			profile: _profile(appIdentifier: "TEAM12345.com.me.*"),
			target: _target(
				appIdentifier: "com.vendor.app",
				override: "com.me.app",
				nested: ["com.vendor.app.widget", "com.vendor.app.share"]
			)
		)

		XCTAssertFalse(evaluation.hasBlocking, _describe(evaluation))
		XCTAssertFalse(
			evaluation.issues.contains { $0.code == .extensionNotCovered },
			_describe(evaluation)
		)
	}

	func testPreflightStillReportsAnExtensionTheRenameDoesNotHelp() {
		let evaluation = ProfileCompatibility.evaluate(
			profile: _profile(appIdentifier: "TEAM12345.com.me.*"),
			target: _target(
				appIdentifier: "com.vendor.app",
				override: "com.me.app",
				nested: ["com.unrelated.widget"]
			)
		)

		XCTAssertTrue(
			evaluation.issues.contains { $0.code == .extensionNotCovered },
			"an extension the rewrite cannot bring under the profile is still reported: \(_describe(evaluation))"
		)
	}

	func testWithoutAnOverrideTheOnDiskIdentifiersAreUsedUnchanged() {
		let evaluation = ProfileCompatibility.evaluate(
			profile: _profile(appIdentifier: "TEAM12345.com.vendor.*"),
			target: _target(appIdentifier: "com.vendor.app", override: nil, nested: ["com.vendor.app.widget"])
		)
		XCTAssertFalse(evaluation.hasBlocking, _describe(evaluation))
	}

	func testABlankOverrideIsNotARewrite() {
		let evaluation = ProfileCompatibility.evaluate(
			profile: _profile(appIdentifier: "TEAM12345.com.vendor.*"),
			target: _target(appIdentifier: "com.vendor.app", override: "   ", nested: ["com.vendor.app.widget"])
		)
		XCTAssertFalse(evaluation.hasBlocking, _describe(evaluation))
	}

	func testCompatibilityModeSeesTheSameRewrittenIdentifiersAsTheBlockingCheck() {
		// The removable set is rewritten too, otherwise an issue would be downgraded to a
		// warning for an identifier the handler will never look for.
		let target = ProfileCompatibility.Target(
			app: _TestApp(identifier: "com.vendor.app"),
			options: _options(identifier: "com.me.app", compatibility: true),
			nestedBundleIdentifiers: ["com.vendor.app.widget"],
			removableExtensionIdentifiers: ["com.vendor.app.widget"]
		)
		XCTAssertEqual(target.nestedBundleIdentifiers, ["com.me.app.widget"])
		XCTAssertEqual(target.removableExtensionIdentifiers, ["com.me.app.widget"])
	}

	func testDefaultOptionsBlockRatherThanAutomaticallyRemoveUncoveredExtension() {
		let target = ProfileCompatibility.Target(
			app: _TestApp(identifier: "com.me.app"),
			options: .defaultOptions,
			nestedBundleIdentifiers: ["com.other.widget"],
			removableExtensionIdentifiers: ["com.other.widget"]
		)
		let evaluation = ProfileCompatibility.evaluate(
			profile: _profile(appIdentifier: "TEAM12345.com.me.*"), target: target
		)
		XCTAssertTrue(evaluation.issues.contains { $0.code == .extensionNotCovered && $0.isBlocking })
	}

	// MARK: - 2. "Sign Anyway" is honoured

	func testUncoveredExtensionStillBlocksWithoutAnOverride() throws {
		let report = NestedBundleAudit.Report(
			entries: [
				NestedBundleAudit.Entry(
					bundle: NestedBundle(path: "PlugIns/Widget.appex", identifier: "com.other.widget", kind: .appExtension),
					coverage: .notCovered(pattern: "TEAM12345.com.me.app"),
					shippedProfileIdentifier: nil
				)
			],
			profilePattern: "TEAM12345.com.me.app"
		)

		XCTAssertFalse(report.isClean)
		XCTAssertThrowsError(try report.requireCompatibleProfile())
		XCTAssertThrowsError(try report.requireCompatibleProfile(overridingBlockingIssues: false))
		XCTAssertNoThrow(
			try report.requireCompatibleProfile(overridingBlockingIssues: true),
			"the preflight sheet offers Sign Anyway; the audit must not veto it"
		)
	}

	func testOverrideDoesNotSilenceTheWarnings() {
		let report = NestedBundleAudit.Report(
			entries: [
				NestedBundleAudit.Entry(
					bundle: NestedBundle(path: "PlugIns/Widget.appex", identifier: "com.other.widget", kind: .appExtension),
					coverage: .notCovered(pattern: "TEAM12345.com.me.app"),
					shippedProfileIdentifier: nil
				)
			],
			profilePattern: "TEAM12345.com.me.app"
		)
		XCTAssertNoThrow(try report.requireCompatibleProfile(overridingBlockingIssues: true))
		XCTAssertFalse(report.warnings.isEmpty, "overriding changes the verdict, not the report")
		XCTAssertTrue(report.warnings[0].contains("Widget.appex"))
	}

	func testACleanReportIsUnaffectedByTheOverride() {
		let report = NestedBundleAudit.Report(entries: [], profilePattern: nil)
		XCTAssertNoThrow(try report.requireCompatibleProfile())
		XCTAssertNoThrow(try report.requireCompatibleProfile(overridingBlockingIssues: true))
	}

	// MARK: - 3. An upgrade must not re-enable a destructive choice

	func testSavedOffChoiceSurvivesADecode() throws {
		var options = Options.defaultOptions
		options.autoRemoveUnsupportedExtensions = false
		let decoded = try JSONDecoder().decode(Options.self, from: JSONEncoder().encode(options))
		XCTAssertFalse(decoded.autoRemoveUnsupportedExtensions)
	}

	func testOptionsManagerKeepsASavedOffChoice() throws {
		let suite = "ExtensionSigningRegressionTests-\(UUID().uuidString)"
		let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
		defer { defaults.removePersistentDomain(forName: suite) }

		var saved = Options.defaultOptions
		saved.autoRemoveUnsupportedExtensions = false
		defaults.set(try JSONEncoder().encode(saved), forKey: "signing_options")

		// The migration used to key off its own flag and force the value true on the first
		// launch after an upgrade. The manager no longer has that flag, so what was persisted
		// is what loads.
		let reloaded = try JSONDecoder().decode(
			Options.self, from: XCTUnwrap(defaults.data(forKey: "signing_options")))
		XCTAssertFalse(reloaded.autoRemoveUnsupportedExtensions)
	}

	func testTheDestructiveMigrationFlagIsGone() throws {
		// The flag's only purpose was to force the toggle on once. Keeping it would let the
		// behaviour come back by accident.
		let source = URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent()            // VexSignTests
			.deletingLastPathComponent()            // repo root
			.appendingPathComponent("VexSign/Backend/Observable/OptionsManager.swift")
		guard let text = try? String(contentsOf: source, encoding: .utf8) else {
			throw XCTSkip("source file not available in this test bundle layout")
		}
		XCTAssertFalse(text.contains("auto_remove_unsupported_extensions_migrated"))
		XCTAssertFalse(text.contains("loadedOptions.autoRemoveUnsupportedExtensions = true"))
	}

	// MARK: - Fixtures

	private struct _TestApp: AppInfoPresentable {
		var identifier: String?
		let name: String? = "Example"
		let version: String? = "1.0"
		let originalIdentifier: String? = nil
		let date: Date? = nil
		let icon: String? = nil
		let uuid: String? = "extension-regression"
		let isSigned: Bool = false
		var appDescription: String?
	}

	private func _options(identifier: String, compatibility: Bool) -> Options {
		var options = Options.defaultOptions
		options.appIdentifier = identifier
		options.autoRemoveUnsupportedExtensions = compatibility
		return options
	}

	private func _target(
		appIdentifier: String,
		override: String?,
		nested: [String]
	) -> ProfileCompatibility.Target {
		ProfileCompatibility.Target(
			app: _TestApp(identifier: appIdentifier),
			options: _options(identifier: override ?? "", compatibility: false),
			nestedBundleIdentifiers: nested,
			removableExtensionIdentifiers: Set(nested)
		)
	}

	private func _profile(appIdentifier: String) -> Certificate {
		Certificate(
			AppIDName: "Fixture",
			ApplicationIdentifierPrefix: ["TEAM12345"],
			CreationDate: Date().addingTimeInterval(-60 * 60 * 24),
			Platform: ["iOS"],
			IsXcodeManaged: nil,
			DeveloperCertificates: nil,
			derEncodedProfile: nil,
			PPQCheck: nil,
			Entitlements: ["application-identifier": AnyCodable(appIdentifier)],
			ExpirationDate: Date().addingTimeInterval(60 * 60 * 24 * 30),
			Name: "Fixture Profile",
			ProvisionsAllDevices: false,
			ProvisionedDevices: nil,
			TeamIdentifier: ["TEAM12345"],
			TeamName: "Fixture Team",
			TimeToLive: 365,
			UUID: "EXTENSION-REGRESSION",
			Version: 1
		)
	}

	private func _describe(_ evaluation: ProfileCompatibility.Evaluation) -> String {
		evaluation.issues.map { "\($0.code): \($0.detail)" }.joined(separator: " | ")
	}
}
