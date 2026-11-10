//
//  SignedCopyRetentionTests.swift
//  VexSignTests
//
//  The "Keep only the newest signed copy" rule.
//
//  The rule compared versions and nothing else. A re-sign produces a copy with the version of the
//  copy it was started from, so the two tied, and which one survived depended on the order the
//  rows were fetched in: the rule could delete the copy that had just been signed and keep the
//  one it replaced. These tests pin the order the rule now uses - version, then the date the
//  copy was added - and that the answer no longer depends on the order of the rows.
//

import Foundation
import XCTest
@testable import VexSign

final class SignedCopyRetentionTests: XCTestCase {
	private typealias Copy = SignedCopyRetention.Copy

	private static let reference = Date(timeIntervalSince1970: 1_800_000_000)

	private func copy(
		_ uuid: String,
		app: String = "com.example.app",
		version: String? = "1.0",
		addedAfter seconds: TimeInterval? = 0
	) -> Copy {
		Copy(uuid: uuid, app: app, version: version, date: seconds.map { Self.reference.addingTimeInterval($0) })
	}

	private func removed(_ copies: [Copy]) -> [String] {
		SignedCopyRetention.surplus(among: copies).map(\.uuid)
	}

	// MARK: - A re-sign

	func testAReSignedCopyOutlivesTheCopyItWasStartedFrom() {
		let original = copy("original", addedAfter: 0)
		let resigned = copy("resigned", addedAfter: 3_600)

		XCTAssertEqual(removed([original, resigned]), ["original"])
		XCTAssertEqual(removed([resigned, original]), ["original"], "Whichever row happens to be fetched first")
	}

	func testEveryReSignOfTheSameVersionLeavesOnlyTheLatest() {
		let copies = (0..<5).map { copy("sign-\($0)", addedAfter: TimeInterval($0) * 60) }

		XCTAssertEqual(Set(removed(copies.shuffled())), ["sign-0", "sign-1", "sign-2", "sign-3"])
	}

	// MARK: - Versions

	func testTheHighestVersionIsKeptEvenWhenAnOlderOneWasAddedLater() {
		let newer = copy("v2", version: "2.0", addedAfter: 0)
		let olderAddedLater = copy("v1", version: "1.0", addedAfter: 86_400)

		XCTAssertEqual(removed([olderAddedLater, newer]), ["v1"])
	}

	func testVersionsAreComparedAsNumbers() {
		XCTAssertEqual(removed([copy("nine", version: "1.9"), copy("ten", version: "1.10")]), ["nine"])
		XCTAssertEqual(removed([copy("two", version: "2"), copy("ten", version: "10")]), ["two"])
		// A component with more than six digits used to be compared as text against a padded one.
		XCTAssertEqual(
			removed([copy("small", version: "1.0.999999"), copy("dated", version: "1.0.20240501")]),
			["small"]
		)
	}

	func testTrailingZerosAreNotAHigherVersion() {
		let short = copy("short", version: "1.2", addedAfter: 600)
		let long = copy("long", version: "1.2.0", addedAfter: 0)

		XCTAssertEqual(SignedCopyRetention.versionKey("1.2"), SignedCopyRetention.versionKey("1.2.0"))
		XCTAssertEqual(removed([long, short]), ["long"], "Same version, so the copy added last is kept")
	}

	func testACopyWithoutAReadableVersionSortsBelowTheRest() {
		XCTAssertEqual(removed([copy("none", version: nil, addedAfter: 600), copy("one", version: "0.1")]), ["none"])
		XCTAssertEqual(removed([copy("words", version: "beta", addedAfter: 600), copy("one", version: "0.1")]), ["words"])
	}

	// MARK: - Dates

	func testACopyWithoutADateIsTreatedAsTheOldest() {
		XCTAssertEqual(removed([copy("undated", addedAfter: nil), copy("dated", addedAfter: 0)]), ["undated"])
	}

	func testCopiesThatTieOnEverythingAreSettledTheSameWayEveryTime() {
		let first = copy("aaaa")
		let second = copy("bbbb")

		XCTAssertEqual(removed([first, second]), ["bbbb"])
		XCTAssertEqual(removed([second, first]), ["bbbb"])
	}

	// MARK: - What counts as a duplicate

	func testCopiesOfDifferentAppsAreNotDuplicates() {
		let copies = [
			copy("a", app: "com.example.one"),
			copy("b", app: "com.example.two"),
			copy("c", app: "Unnamed App")
		]

		XCTAssertEqual(removed(copies), [])
	}

	func testASingleCopyIsNeverRemoved() {
		XCTAssertEqual(removed([copy("only")]), [])
		XCTAssertEqual(removed([]), [])
	}

	func testACopyListedTwiceIsNotItsOwnDuplicate() {
		let only = copy("only")

		XCTAssertEqual(removed([only, only]), [], "Removing \"the other one\" would remove the only copy")
	}

	// MARK: - The whole library

	func testEveryAppKeepsExactlyOneCopyWhateverTheOrderOfTheRows() {
		let library = [
			copy("one-old", app: "one", version: "1.0", addedAfter: 0),
			copy("one-resigned", app: "one", version: "1.0", addedAfter: 500),
			copy("one-update", app: "one", version: "1.1", addedAfter: 100),
			copy("two-a", app: "two", version: "3.0", addedAfter: 0),
			copy("two-b", app: "two", version: "3.0", addedAfter: 900),
			copy("three", app: "three", version: "0.9", addedAfter: 0)
		]
		let expected: Set<String> = ["one-old", "one-resigned", "two-a"]

		var orders = Set<[String]>()
		for _ in 0..<50 {
			let shuffled = library.shuffled()
			let surplus = SignedCopyRetention.surplus(among: shuffled)

			XCTAssertEqual(Set(surplus.map(\.uuid)), expected)
			orders.insert(surplus.map(\.uuid))

			let kept = shuffled.filter { copy in !surplus.contains(copy) }
			XCTAssertEqual(Set(kept.map(\.app)), ["one", "two", "three"], "No app loses its last copy")
			XCTAssertEqual(kept.count, 3)
		}
		XCTAssertEqual(orders.count, 1, "The result comes back in one fixed order")
	}
}
