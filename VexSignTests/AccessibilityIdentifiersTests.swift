//
//  AccessibilityIdentifiersTests.swift
//  VexSignTests
//
//  Tests for the identifiers a UI test drives the signing and install flows by.
//
//  An identifier is a contract. If two views share one, a test finds the wrong control; if one
//  loses the prefix, a stale reference is no longer recognisable in a failure log; if one is
//  renamed, the test that used it stops compiling — which is the point, so the names live in
//  `AX` and nowhere else.
//

import Foundation
import XCTest
@testable import VexSign

final class AccessibilityIdentifiersTests: XCTestCase {
	func testEveryIdentifierCarriesThePrefix() {
		for identifier in AX.all {
			XCTAssertTrue(
				identifier.hasPrefix(AX.prefix + "."),
				"\(identifier) does not start with \(AX.prefix)"
			)
		}
	}

	func testIdentifiersAreUnique() {
		XCTAssertEqual(
			Set(AX.all).count,
			AX.all.count,
			"two views share an identifier: \(AX.all)"
		)
	}

	/// A UI test matcher leans on the shape (`prefix.flow.element`), so an identifier with a space
	/// or a single segment is a sign it was written by hand somewhere else.
	func testIdentifiersAreDottedAndFreeOfWhitespace() {
		for identifier in AX.all {
			XCTAssertFalse(identifier.contains(" "), "\(identifier) contains a space")
			XCTAssertGreaterThanOrEqual(
				identifier.split(separator: ".").count,
				3,
				"\(identifier) should read as \(AX.prefix).flow.element"
			)
		}
	}

	/// The flows names: signing, installing, and what a library row says about an app.
	func testTheSigningInstallAndLibraryFlowsAreCovered() {
		let expected = [
			AX.Signing.start,
			AX.Signing.stop,
			AX.Signing.progress,
			AX.Signing.console,
			AX.Install.start,
			AX.Install.progress,
			AX.Library.installedBadge,
			AX.Library.updateBadge,
			AX.Library.lockBadge
		]

		for identifier in expected {
			XCTAssertTrue(AX.all.contains(identifier), "\(identifier) is not exposed through AX.all")
		}
		XCTAssertEqual(Set(expected).count, AX.all.count, "AX.all carries an identifier no test expects")
	}
}
