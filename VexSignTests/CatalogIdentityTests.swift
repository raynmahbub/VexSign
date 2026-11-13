//
//  CatalogIdentityTests.swift
//  VexSignTests
//
//  Catalog identity has to be deterministic: the same catalog must produce the same keys on any
//  device, and two spellings of one repository or one bundle identifier must not become two
//  applications. These tests are the contract for that.
//

import Foundation
import XCTest
@testable import VexSign

final class CatalogIdentityTests: XCTestCase {
	// MARK: - Bundle identifiers

	func testBundleKeyNormalizesCaseAndWhitespace() {
		XCTAssertEqual(CatalogIdentity.bundleKey("  com.Example.App  "), "com.example.app")
		XCTAssertEqual(CatalogIdentity.bundleKey("COM.EXAMPLE.APP"), "com.example.app")
		XCTAssertEqual(CatalogIdentity.bundleKey("com.example.app."), "com.example.app")
	}

	func testMissingBundleIdentifierHasNoKey() {
		XCTAssertNil(CatalogIdentity.bundleKey(nil))
		XCTAssertNil(CatalogIdentity.bundleKey(""))
		XCTAssertNil(CatalogIdentity.bundleKey("   "))
		XCTAssertNil(CatalogIdentity.bundleKey("..."))
	}

	func testWellFormedDistinguishesMissingFromMalformed() {
		XCTAssertTrue(CatalogIdentity.isWellFormed(bundleIdentifier: "com.example.app"))
		XCTAssertTrue(CatalogIdentity.isWellFormed(bundleIdentifier: "com.example-app.widget2"))

		XCTAssertFalse(CatalogIdentity.isWellFormed(bundleIdentifier: ""))
		XCTAssertFalse(CatalogIdentity.isWellFormed(bundleIdentifier: "notanid"))
		XCTAssertFalse(CatalogIdentity.isWellFormed(bundleIdentifier: "com..app"))
		XCTAssertFalse(CatalogIdentity.isWellFormed(bundleIdentifier: "com.example_app"))
		XCTAssertFalse(CatalogIdentity.isWellFormed(bundleIdentifier: ".com.example"))
	}

	// MARK: - Source addresses

	func testTrailingSlashAndCaseAreTheSameSource() {
		let canonical = CatalogIdentity.sourceKey("https://example.com/repo.json")
		XCTAssertEqual(canonical, CatalogIdentity.sourceKey("https://example.com/repo.json/"))
		XCTAssertEqual(canonical, CatalogIdentity.sourceKey("HTTPS://Example.COM/repo.json"))
		XCTAssertEqual(canonical, "https://example.com/repo.json")
	}

	func testDefaultPortAndFragmentAreNormalizedAway() {
		XCTAssertEqual(
			CatalogIdentity.sourceKey("https://example.com:443/repo.json#top"),
			"https://example.com/repo.json"
		)
		XCTAssertEqual(
			CatalogIdentity.sourceKey("http://example.com:80/repo.json"),
			"http://example.com/repo.json"
		)
		// A non-default port is part of the address and must survive.
		XCTAssertEqual(
			CatalogIdentity.sourceKey("https://example.com:8443/repo.json"),
			"https://example.com:8443/repo.json"
		)
	}

	func testNonDefaultQueryIsPreservedButAnEmptyOneIsNot() {
		XCTAssertEqual(
			CatalogIdentity.sourceKey("https://example.com/repo?format=json"),
			"https://example.com/repo?format=json"
		)
		XCTAssertEqual(CatalogIdentity.sourceKey("https://example.com/repo?"), "https://example.com/repo")
	}

	func testUnusableAddressesHaveNoKey() {
		XCTAssertNil(CatalogIdentity.sourceKey(""))
		XCTAssertNil(CatalogIdentity.sourceKey("   "))
		XCTAssertNil(CatalogIdentity.sourceKey("not a url"))
		XCTAssertNil(CatalogIdentity.sourceKey("file:///tmp/repo.json"))
		XCTAssertNil(CatalogIdentity.sourceKey("data:text/plain,hello"))
		XCTAssertNil(CatalogIdentity.sourceKey("https://user:pass@example.com/repo.json"))
	}

	func testSameSourceComparison() {
		XCTAssertTrue(CatalogIdentity.isSameSource("https://example.com/repo.json/", "https://EXAMPLE.com/repo.json"))
		XCTAssertFalse(CatalogIdentity.isSameSource("https://example.com/a.json", "https://example.com/b.json"))
		// Two unusable addresses are not "the same repository" just because both failed.
		XCTAssertFalse(CatalogIdentity.isSameSource("file:///a", "file:///b"))
	}

	// MARK: - Listing identity

	func testListingIDIsStableAndSourceScoped() throws {
		let first = try XCTUnwrap(CatalogIdentity.appID(source: "https://example.com/repo.json", bundleIdentifier: "com.example.app"))
		let second = try XCTUnwrap(CatalogIdentity.appID(source: "https://example.com/repo.json/", bundleIdentifier: "COM.Example.App"))

		XCTAssertEqual(first, second, "the same repository and the same app must produce one id")
		XCTAssertEqual(first, "https://example.com/repo.json#com.example.app")

		let other = try XCTUnwrap(CatalogIdentity.appID(source: "https://other.example/repo.json", bundleIdentifier: "com.example.app"))
		XCTAssertNotEqual(first, other, "two publishers of one bundle id are two listings")
	}

	func testListingWithoutAnIdentifierHasNoIdentity() {
		XCTAssertNil(CatalogIdentity.appID(source: "https://example.com/repo.json", bundleIdentifier: nil))
		XCTAssertNil(CatalogIdentity.appID(source: "https://example.com/repo.json", bundleIdentifier: "  "))
		XCTAssertNil(CatalogIdentity.appID(source: "", bundleIdentifier: "com.example.app"))
	}

	// MARK: - Discovery grouping

	// `source` is last because every call site supplies it last: Swift argument lists are
	// positional for the purpose of ordering, and the previous order did not compile.
	private func app(
		bundleIdentifier: String = "com.example.app",
		version: String = "1.0",
		updated: Date? = Date(timeIntervalSince1970: 1_000),
		name: String = "Example",
		source: String = "https://example.com/repo.json"
	) -> DiscoveryApp {
		DiscoveryApp(
			id: CatalogIdentity.appID(source: source, bundleIdentifier: bundleIdentifier) ?? "invalid",
			source: source,
			bundleIdentifier: bundleIdentifier,
			name: name,
			summary: "",
			developer: "Dev",
			category: "Utilities",
			version: version,
			icon: nil,
			download: nil,
			updated: updated,
			releases: 1
		)
	}

	func testGroupingIgnoresIdentifierCase() async {
		let index = DiscoveryIndex()
		await index.replace([
			app(bundleIdentifier: "com.example.app", source: "https://a.example/repo.json"),
			app(bundleIdentifier: "COM.Example.App", source: "https://b.example/repo.json")
		])

		let groups = await index.canonicalGroups()
		XCTAssertEqual(groups.count, 1, "two casings of one identifier are one application")
		XCTAssertEqual(groups.first?.versions.count, 2)
		XCTAssertEqual(groups.first?.sourceCount, 2)
		XCTAssertEqual(groups.first?.bundleIdentifier, "com.example.app")
	}

	func testPrimaryListingIsDeterministicWhenDatesTie() async {
		let sameDate = Date(timeIntervalSince1970: 5_000)
		let a = app(version: "1.0", updated: sameDate, source: "https://a.example/repo.json")
		let b = app(version: "1.0", updated: sameDate, source: "https://b.example/repo.json")
		let c = app(version: "1.0", updated: sameDate, source: "https://c.example/repo.json")

		let forward = DiscoveryIndex()
		await forward.replace([a, b, c])
		let backward = DiscoveryIndex()
		await backward.replace([c, b, a])

		let forwardGroups = await forward.canonicalGroups()
		let backwardGroups = await backward.canonicalGroups()

		XCTAssertEqual(forwardGroups.first?.versions.count, 3)
		XCTAssertEqual(
			forwardGroups.first?.primaryApp.id,
			backwardGroups.first?.primaryApp.id,
			"the same catalogs in another order must choose the same primary listing"
		)
		// The tie-break is the lower canonical source key, which does not depend on input order.
		XCTAssertEqual(forwardGroups.first?.primaryApp.source, "https://a.example/repo.json")
	}

	func testPreferredOrderUsesDateThenVersionThenSource() {
		let newer = app(version: "1.0", updated: Date(timeIntervalSince1970: 9_000))
		let older = app(version: "3.0", updated: Date(timeIntervalSince1970: 1_000))
		XCTAssertTrue(DiscoveryApp.isPreferred(newer, over: older), "a newer date outranks a higher version")

		let sameDate = Date(timeIntervalSince1970: 5_000)
		let high = app(version: "2.0", updated: sameDate, source: "https://b.example/repo.json")
		let low = app(version: "1.0", updated: sameDate, source: "https://a.example/repo.json")
		XCTAssertTrue(DiscoveryApp.isPreferred(high, over: low), "same date: the higher version wins")

		let tieA = app(version: "1.0", updated: sameDate, source: "https://a.example/repo.json")
		let tieB = app(version: "1.0", updated: sameDate, source: "https://b.example/repo.json")
		XCTAssertTrue(DiscoveryApp.isPreferred(tieA, over: tieB), "full tie: the lower source key wins")
		XCTAssertFalse(DiscoveryApp.isPreferred(tieB, over: tieA))
		XCTAssertFalse(DiscoveryApp.isPreferred(tieA, over: tieA), "the preference must be irreflexive")
	}

	func testVersionsLookupIsCaseInsensitive() async {
		let index = DiscoveryIndex()
		await index.replace([
			app(bundleIdentifier: "com.example.app", version: "1.0", source: "https://a.example/repo.json"),
			app(bundleIdentifier: "COM.Example.App", version: "2.0", source: "https://b.example/repo.json")
		])

		let versions = await index.versions(for: "COM.EXAMPLE.APP")
		XCTAssertEqual(versions.count, 2)
		XCTAssertEqual(versions.first?.version, "2.0")
	}

	func testVersionsFromOneSourceStayOneSource() async {
		let index = DiscoveryIndex()
		await index.replace([
			app(version: "1.0", updated: Date(timeIntervalSince1970: 1_000)),
			app(version: "2.0", updated: Date(timeIntervalSince1970: 2_000))
		])

		let groups = await index.canonicalGroups()
		XCTAssertEqual(groups.first?.versions.count, 2)
		XCTAssertEqual(groups.first?.sourceCount, 1)
		XCTAssertEqual(groups.first?.primaryApp.version, "2.0")
	}
}
