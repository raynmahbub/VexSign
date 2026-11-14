//
//  AccessibilityIdentifiersTests.swift
//  VexSignTests
//
//  Tests for the identifiers a UI test drives the signing and install flows by.
//
//  An identifier is a contract. If two views share one, a test finds the wrong control; if one
//  loses the prefix, a stale reference is no longer recognisable in a failure log; if one is
//  renamed, the test that used it stops compiling — which is the point, so the names live in
//  `A11y` and nowhere else.
//

import Foundation
import XCTest
@testable import VexSign

final class AccessibilityIdentifiersTests: XCTestCase {
	func testEveryIdentifierCarriesThePrefix() {
		for identifier in A11y.all {
			XCTAssertTrue(
				identifier.hasPrefix(A11y.prefix + "."),
				"\(identifier) does not start with \(A11y.prefix)"
			)
		}
	}

	func testIdentifiersAreUnique() {
		XCTAssertEqual(
			Set(A11y.all).count,
			A11y.all.count,
			"two views share an identifier: \(A11y.all)"
		)
	}

	/// A UI test matcher leans on the shape (`prefix.flow.element`), so an identifier with a space
	/// or a single segment is a sign it was written by hand somewhere else.
	func testIdentifiersAreDottedAndFreeOfWhitespace() {
		for identifier in A11y.all {
			XCTAssertFalse(identifier.contains(" "), "\(identifier) contains a space")
			XCTAssertGreaterThanOrEqual(
				identifier.split(separator: ".").count,
				3,
				"\(identifier) should read as \(A11y.prefix).flow.element"
			)
		}
	}

	/// The flows names: signing, installing, and what a library row says about an app.
	func testTheSigningInstallAndLibraryFlowsAreCovered() {
		let expected = [
			A11y.Signing.start,
			A11y.Signing.stop,
			A11y.Signing.progress,
			A11y.Signing.console,
			A11y.Signing.workflow,
			A11y.Signing.attemptWorkflow,
			A11y.Signing.preflightCannotSign,
			A11y.Install.start,
			A11y.Install.progress,
			A11y.Install.appName,
			A11y.Install.status,
			A11y.Home.search,
			A11y.Home.importPackages,
			A11y.Library.installedBadge,
			A11y.Library.guestBadge,
			A11y.Library.updateBadge,
			A11y.Library.lockBadge,
			A11y.Library.resign,
			A11y.Library.export,
			A11y.Library.selectionToggle
		]

		for identifier in expected {
			XCTAssertTrue(A11y.all.contains(identifier), "\(identifier) is not exposed through A11y.all")
		}
		XCTAssertEqual(Set(expected).count, A11y.all.count, "A11y.all carries an identifier no test expects")
	}
}
