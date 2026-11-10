//
//  VersionOrderTests.swift
//  VexSignTests
//
//  Version precedence, the rule three places used to decide for themselves.
//
//  The regression this pins: `DownloadButtonView` compared dotted integers and dropped every
//  component that was not an `Int`, so `"1.1-beta"` became `[1]` and lost to `"1.0"`'s `[1, 0]`.
//  The App Store detail screen therefore said a beta of a newer version carried no update, while
//  the Updates list — built on `AppUpdateChecker`'s SemVer-aware comparison — offered it as one.
//

import Foundation
import XCTest
@testable import VexSign

final class VersionOrderTests: XCTestCase {
	// MARK: - Dotted numbers

	func testDottedVersionsCompareAsNumbersNotText() {
		XCTAssertTrue(VersionOrder.isNewer("1.10", than: "1.9"), "'1.10' sorts below '1.9' as text")
		XCTAssertFalse(VersionOrder.isNewer("1.9", than: "1.10"))
		XCTAssertTrue(VersionOrder.isNewer("2.0", than: "1.9.9"))
		XCTAssertTrue(VersionOrder.isNewer("18.1.1", than: "18.1"))
	}

	func testTrailingZerosAndALeadingVDoNotChangePrecedence() {
		XCTAssertEqual(VersionOrder.precedence("1.0.0", "1.0"), .orderedSame)
		XCTAssertFalse(VersionOrder.isNewer("1.0.0", than: "1.0"))
		XCTAssertFalse(VersionOrder.isNewer("1.0", than: "1.0.0"))
		XCTAssertTrue(VersionOrder.isNewer("v2.0", than: "1.9"))
		XCTAssertEqual(VersionOrder.precedence("09", "9"), .orderedSame)
	}

	// MARK: - Prereleases

	func testAPrereleaseNeverOutranksItsRelease() {
		XCTAssertTrue(VersionOrder.isNewer("1.0", than: "1.0-beta"))
		XCTAssertFalse(VersionOrder.isNewer("1.0-beta", than: "1.0"))
		XCTAssertFalse(VersionOrder.isNewer("1.0.0-beta", than: "1.0.0-beta.1"))
		XCTAssertTrue(VersionOrder.isNewer("1.0.0-beta.1", than: "1.0.0-beta"))
		XCTAssertTrue(VersionOrder.isNewer("1.0.0-beta.2", than: "1.0.0-beta.1"))
		XCTAssertFalse(VersionOrder.isNewer("1.0.0-alpha", than: "1.0.0-beta"))
		// Numeric identifiers sort below alphanumeric ones in SemVer.
		XCTAssertFalse(VersionOrder.isNewer("1.0.0-1", than: "1.0.0-alpha"))
	}

	func testABetaOfANewerVersionIsStillAnUpdate() {
		// The exact pair the two copies disagreed about: the dotted comparator read "1.1-beta"
		// as [1] and answered "not newer".
		XCTAssertTrue(VersionOrder.isNewer("1.1-beta", than: "1.0"))
		XCTAssertTrue(VersionOrder.isNewer("1.1-beta", than: "1.0.9"))
		XCTAssertFalse(VersionOrder.isNewer("1.0-beta", than: "1.0"))
	}

	func testBuildMetadataIsIgnored() {
		XCTAssertEqual(VersionOrder.precedence("1.0.0+1", "1.0.0+2"), .orderedSame)
		XCTAssertFalse(VersionOrder.isNewer("1.0.0+2", than: "1.0.0+1"))
		XCTAssertTrue(VersionOrder.isNewer("1.0.1+1", than: "1.0.0+9"))
	}

	// MARK: - Failing closed

	func testWhatIsNotAVersionCannotBeOrdered() {
		for pair in [("beta", "1.0"), ("", "1.0"), ("1..0", "1.0"), ("one.two", "1.0")] {
			XCTAssertNil(VersionOrder.precedence(pair.0, pair.1),
						 "\(pair.0) is not a version and must not manufacture an order")
			XCTAssertFalse(VersionOrder.isNewer(pair.0, than: pair.1))
			XCTAssertFalse(VersionOrder.isNewer(pair.1, than: pair.0),
						   "failing closed means neither direction claims an update")
		}
	}

	func testOrderingIsAntisymmetric() {
		// `1.0` and `1.0.0+build` are the same version, so they are neither ordered nor unequal;
		// every other pair must resolve in exactly one direction.
		let versions = ["1.0", "1.0.1", "1.1-beta", "1.10", "2.0", "v3.0", "1.0.0+build"]
		for lhs in versions {
			for rhs in versions where lhs != rhs {
				let forward = VersionOrder.isNewer(lhs, than: rhs)
				let backward = VersionOrder.isNewer(rhs, than: lhs)
				XCTAssertFalse(forward && backward, "\(lhs) and \(rhs) cannot both be newer")
				if !forward && !backward {
					XCTAssertEqual(VersionOrder.precedence(lhs, rhs), .orderedSame,
								   "\(lhs) and \(rhs) are neither ordered nor equal")
				}
			}
		}
	}

	// MARK: - Optional versions, for picking a library copy

	func testAVersionOutranksAMissingOne() {
		XCTAssertTrue(VersionOrder.isOrderedBefore(nil, "1.0"))
		XCTAssertFalse(VersionOrder.isOrderedBefore("1.0", nil))
		XCTAssertTrue(VersionOrder.isOrderedBefore("1.9", "1.10"))
		XCTAssertFalse(VersionOrder.isOrderedBefore("1.10", "1.9"))
	}

	func testTwoVersionsThatCannotBeOrderedKeepTheirOrder() {
		// Stable for the caller: `max(by:)` then keeps the copy it saw first.
		XCTAssertFalse(VersionOrder.isOrderedBefore(nil, nil))
		XCTAssertFalse(VersionOrder.isOrderedBefore("1.0", "1.0"))
		XCTAssertFalse(VersionOrder.isOrderedBefore("beta", nil))
		XCTAssertFalse(VersionOrder.isOrderedBefore(nil, "beta"))
	}

	// MARK: - The firmware browser keeps its own results

	func testTheFirmwareCompareStillOrdersNumerically() {
		XCTAssertTrue(IPSWBrowser._versionCompare("18.1", "17.5.2"))
		XCTAssertFalse(IPSWBrowser._versionCompare("17.5.2", "18.1"))
		XCTAssertFalse(IPSWBrowser._versionCompare("18.1", "18.1"))
		XCTAssertTrue(IPSWBrowser._versionCompare("18.1.1", "18.1"))
	}
}
