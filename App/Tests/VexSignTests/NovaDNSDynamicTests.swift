//
//  NovaDNSDynamicTests.swift
//  VexSignTests
//
//  Tests for the anti-revoke service endpoint is configurable, visible, and strict about
//  what it will accept. The feature itself stays off unless a user turns it on.
//

import Foundation
import XCTest
@testable import VexSign

final class NovaDNSDynamicTests: XCTestCase {
	override func setUp() {
		super.setUp()
		UserDefaults.standard.removeObject(forKey: NovaDNSDynamic.customRulesURLKey)
		UserDefaults.standard.removeObject(forKey: "VexSign.dynamicDNSRulesCache")
	}

	override func tearDown() {
		UserDefaults.standard.removeObject(forKey: NovaDNSDynamic.customRulesURLKey)
		UserDefaults.standard.removeObject(forKey: "VexSign.dynamicDNSRulesCache")
		super.tearDown()
	}

	// MARK: - Default

	func testUnsetOverrideUsesTheBuiltInDefault() {
		XCTAssertNil(NovaDNSDynamic.customRulesURL)
		XCTAssertEqual(NovaDNSDynamic.effectiveRulesURLString, NovaDNSDynamic.defaultRulesURL)
		XCTAssertEqual(NovaDNSDynamic.rulesURL?.host, "api.novadev.vip")
	}

	// MARK: - Override

	func testHttpsOverrideIsStoredAndTrimmed() {
		XCTAssertTrue(NovaDNSDynamic.setCustomRulesURL("  https://rules.example.com/nova/rules.json \n"))
		XCTAssertEqual(NovaDNSDynamic.customRulesURL, "https://rules.example.com/nova/rules.json")
		XCTAssertEqual(NovaDNSDynamic.effectiveRulesURLString, "https://rules.example.com/nova/rules.json")
	}

	func testPlainHTTPIsRejectedAndTheDefaultSurvives() {
		XCTAssertFalse(NovaDNSDynamic.setCustomRulesURL("http://rules.example.com/rules.json"))
		XCTAssertNil(NovaDNSDynamic.customRulesURL)
		XCTAssertEqual(NovaDNSDynamic.effectiveRulesURLString, NovaDNSDynamic.defaultRulesURL)
	}

	func testNonURLIsRejected() {
		XCTAssertFalse(NovaDNSDynamic.setCustomRulesURL("not a url"))
		XCTAssertFalse(NovaDNSDynamic.setCustomRulesURL("https://"))
		XCTAssertNil(NovaDNSDynamic.customRulesURL)
	}

	func testEmptyOverrideClearsTheCustomEndpoint() {
		XCTAssertTrue(NovaDNSDynamic.setCustomRulesURL("https://rules.example.com/nova/rules.json"))
		XCTAssertTrue(NovaDNSDynamic.setCustomRulesURL("   "))
		XCTAssertNil(NovaDNSDynamic.customRulesURL)
		XCTAssertEqual(NovaDNSDynamic.effectiveRulesURLString, NovaDNSDynamic.defaultRulesURL)
	}

	// MARK: - Actions follow the endpoint

	func testActionURLSitsBesideTheRuleList() {
		XCTAssertEqual(
			NovaDNSDynamic.actionURL("enablePPQ")?.absoluteString,
			"https://api.novadev.vip/api/novadns-dynamic/enablePPQ"
		)
	}

	func testActionURLFollowsACustomEndpoint() {
		NovaDNSDynamic.setCustomRulesURL("https://rules.example.com/nova/rules.json")
		XCTAssertEqual(
			NovaDNSDynamic.actionURL("enablePPQ")?.absoluteString,
			"https://rules.example.com/nova/enablePPQ"
		)
	}

	// MARK: - Rules cache

	func testCachedRulesRoundTrip() {
		let rules = DynamicDNSRules(
			version: 7,
			lastUpdated: "2026-11-01",
			primaryEndpoint: "https://dns.example.com/dns-query",
			fallbackEndpoints: nil,
			blockedHosts: ["ocsp.apple.com"]
		)
		NovaDNSDynamic.saveCachedRules(rules)

		let loaded = NovaDNSDynamic.loadCachedRules()
		XCTAssertEqual(loaded.version, 7)
		XCTAssertEqual(loaded.primaryEndpoint, "https://dns.example.com/dns-query")
		XCTAssertEqual(loaded.blockedHosts, ["ocsp.apple.com"])
	}

	func testNoCacheFallsBackToDefaultRules() {
		XCTAssertEqual(NovaDNSDynamic.loadCachedRules().version, DynamicDNSRules.default.version)
		XCTAssertTrue(NovaDNSDynamic.loadCachedRules().blockedHosts.contains("ocsp.apple.com"))
	}

	// MARK: - Off by default

	func testFeatureIsOffUntilAUserTurnsItOn() {
		UserDefaults.standard.removeObject(forKey: "VexSign.useNovaDNSDynamic")
		XCTAssertFalse(UserDefaults.standard.bool(forKey: "VexSign.useNovaDNSDynamic"))
	}
}
