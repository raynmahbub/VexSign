//
//  SigningIdentityResolutionTests.swift
//  VexSignTests
//
//  A saved signing profile names the identity it was captured with. Certificates get deleted and
//  replaced, so that reference can outlive the row — and the store used to answer such a profile
//  with whatever happened to be selected, without saying anything. These tests pin down the one
//  rule that keeps automatic re-signing honest: a captured identity that is gone is reported as
//  orphaned, never as the same identity.
//

import XCTest
@testable import VexSign

final class SigningIdentityResolutionTests: XCTestCase {
	private let installed = "8f14e45f-ceea-467a-9575-6b1a1b2c3d4e"

	// MARK: - Resolution

	func testProfileWithoutACapturedIdentityUsesTheCurrentSelection() {
		XCTAssertEqual(SigningProfileStore.resolveIdentity(captured: nil, available: []), .currentSelection)
		XCTAssertEqual(SigningProfileStore.resolveIdentity(captured: "", available: [installed]), .currentSelection)
		XCTAssertEqual(SigningProfileStore.resolveIdentity(captured: "   ", available: [installed]), .currentSelection)
	}

	func testCapturedIdentityThatIsStillInstalledResolvesToIt() {
		XCTAssertEqual(
			SigningProfileStore.resolveIdentity(captured: installed, available: [installed]),
			.captured(uuid: installed)
		)
	}

	func testCapturedIdentityThatWasDeletedIsOrphanedNotSilentlySubstituted() {
		let resolution = SigningProfileStore.resolveIdentity(captured: installed, available: ["another-certificate"])
		XCTAssertEqual(resolution, .orphaned(uuid: installed))
		XCTAssertTrue(resolution.isOrphaned)
		XCTAssertEqual(resolution.capturedUUID, installed)
	}

	func testResolutionIgnoresCaseAndSurroundingWhitespace() {
		XCTAssertEqual(
			SigningProfileStore.resolveIdentity(captured: "  \(installed.uppercased())  ", available: [installed]),
			.captured(uuid: installed)
		)
	}

	func testEmptyInventoryOrphansEveryCapturedReference() {
		let resolution = SigningProfileStore.resolveIdentity(captured: installed, available: [])
		XCTAssertTrue(resolution.isOrphaned)
		XCTAssertNotEqual(resolution, .captured(uuid: installed))
	}

	func testOnlyACapturedReferenceCanBeOrphaned() {
		XCTAssertFalse(SigningIdentityResolution.currentSelection.isOrphaned)
		XCTAssertNil(SigningIdentityResolution.currentSelection.capturedUUID)
		XCTAssertFalse(SigningIdentityResolution.captured(uuid: installed).isOrphaned)
		XCTAssertEqual(SigningIdentityResolution.captured(uuid: installed).capturedUUID, installed)
	}

	func testTwoDifferentCapturedIdentitiesDoNotCollapse() {
		// A re-imported certificate has a new row and a new uuid. The old reference must stay
		// orphaned even though a certificate with the same common name exists.
		let reimported = "0f8b8c0e-1111-2222-3333-444455556666"
		let resolution = SigningProfileStore.resolveIdentity(captured: installed, available: [reimported])
		XCTAssertEqual(resolution, .orphaned(uuid: installed))
	}

	func testResolutionIsAMappingNotAStoreLookup() {
		// The rule is pure, so the same inputs always produce the same answer, in any order.
		let available: Set<String> = ["a", "b", "c"]
		for _ in 0..<5 {
			XCTAssertEqual(SigningProfileStore.resolveIdentity(captured: "b", available: available), .captured(uuid: "b"))
			XCTAssertEqual(SigningProfileStore.resolveIdentity(captured: "z", available: available), .orphaned(uuid: "z"))
		}
	}
}
