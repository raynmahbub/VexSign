//
//  TweakInjectionDefaultsTests.swift
//  VexSignTests
//
//  the bulk "inject by default" screen. The list logic is pure so it can be tested here
//  without building a view; the view itself is a thin binding over `TweakManager.update`.
//

import Foundation
import XCTest
@testable import VexSign

final class TweakInjectionDefaultsTests: XCTestCase {
	private func tweak(
		_ name: String,
		enabled: Bool = true,
		inject: Bool = false,
		exceptions: [String] = []
	) -> ManagedTweak {
		ManagedTweak(
			name: name,
			notes: nil,
			isEnabled: enabled,
			injectByDefault: inject,
			autoInjectBundleIds: exceptions
		)
	}

	// MARK: - Matching

	func testEmptyQueryMatchesEverything() {
		XCTAssertTrue(TweakInjectionDefaults.matches(tweak("Choicy"), query: ""))
		XCTAssertTrue(TweakInjectionDefaults.matches(tweak("Choicy"), query: "   "))
	}

	func testSearchIsCaseAndDiacriticInsensitive() {
		XCTAssertTrue(TweakInjectionDefaults.matches(tweak("Café Patch"), query: "cafe"))
		XCTAssertTrue(TweakInjectionDefaults.matches(tweak("Choicy"), query: "CHO"))
		XCTAssertFalse(TweakInjectionDefaults.matches(tweak("Choicy"), query: "crane"))
	}

	// MARK: - Bulk apply

	func testApplyTurnsOnEveryEnabledMatchOnly() {
		let tweaks = [
			tweak("A"),
			tweak("B", inject: true),
			tweak("C", enabled: false),
			tweak("D")
		]

		let result = TweakInjectionDefaults.apply(true, to: tweaks, matching: "")

		XCTAssertEqual(result.map(\.injectByDefault), [true, true, false, true])
		// A disabled tweak is not silently switched on.
		XCTAssertFalse(result[2].injectByDefault)
	}

	func testApplyRespectsTheSearch() {
		let tweaks = [tweak("Choicy"), tweak("Crane")]
		let result = TweakInjectionDefaults.apply(true, to: tweaks, matching: "choicy")

		XCTAssertEqual(result.map(\.injectByDefault), [true, false])
	}

	func testApplyIsIdempotent() {
		let tweaks = [tweak("A", inject: true), tweak("B")]
		let once = TweakInjectionDefaults.apply(true, to: tweaks, matching: "")
		let twice = TweakInjectionDefaults.apply(true, to: once, matching: "")

		XCTAssertEqual(once.map(\.injectByDefault), twice.map(\.injectByDefault))
	}

	func testApplyOffLeavesExceptionsAlone() {
		let tweaks = [tweak("A", inject: true, exceptions: ["com.example.app"])]
		let result = TweakInjectionDefaults.apply(false, to: tweaks, matching: "")

		XCTAssertFalse(result[0].injectByDefault)
		XCTAssertEqual(result[0].autoInjectBundleIds, ["com.example.app"])
	}

	// MARK: - The rule the screen describes

	func testOnWithExceptionsSkipsTheListedApp() {
		let tweak = tweak("A", inject: true, exceptions: ["com.example.app"])
		XCTAssertTrue(tweak.autoInjects(into: "com.other.app"))
		XCTAssertFalse(tweak.autoInjects(into: "com.example.app"))
		XCTAssertFalse(tweak.autoInjects(into: "COM.EXAMPLE.APP"))
	}

	func testOffWithAllowListOnlyReachesTheListedApp() {
		let tweak = tweak("A", inject: false, exceptions: ["com.example.app"])
		XCTAssertTrue(tweak.autoInjects(into: "com.example.app"))
		XCTAssertFalse(tweak.autoInjects(into: "com.other.app"))
	}
}
