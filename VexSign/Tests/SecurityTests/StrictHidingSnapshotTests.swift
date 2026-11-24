//
//  StrictHidingSnapshotTests.swift
//  VexSignTests
//
//  Strict Hiding is promised to exclude hidden apps from search, widgets and
//  export suggestions. Search lives in views and can ask the vault directly; the
//  widget payload and the backup writer cannot, so they read this snapshot. These
//  tests pin the mirror's rules so a future change to the vault does not quietly
//  stop feeding it.
//

import XCTest
@testable import VexSign

final class StrictHidingSnapshotTests: XCTestCase {

	func testNothingIsHiddenUntilStrictModeIsOn() {
		let snapshot = StrictHidingSnapshot()
		snapshot.update(isEnabled: false, hiddenAppUUIDs: ["vaulted"])

		XCTAssertFalse(snapshot.hides("vaulted"), "hidden apps are only excluded from other surfaces in strict mode")
		XCTAssertFalse(snapshot.hides("ordinary"), "an unrestricted snapshot must not hide anything")
	}

	func testStrictModeHidesExactlyTheVaultedApps() {
		let snapshot = StrictHidingSnapshot()
		snapshot.update(isEnabled: true, hiddenAppUUIDs: ["vaulted", "also-vaulted"])

		XCTAssertTrue(snapshot.hides("vaulted"))
		XCTAssertTrue(snapshot.hides("also-vaulted"))
		XCTAssertFalse(snapshot.hides("ordinary"), "hiding one app must not remove the others")
	}

	func testRowsWithoutAnIdentityStayVisible() {
		// The vault is keyed by UUID; a row without one cannot be matched, and
		// failing closed would hide unrelated apps from their owner.
		let snapshot = StrictHidingSnapshot()
		snapshot.update(isEnabled: true, hiddenAppUUIDs: ["vaulted"])

		XCTAssertFalse(snapshot.hides(nil))
		XCTAssertFalse(snapshot.hides(""))
	}

	func testUpdateReplacesRatherThanAccumulates() {
		let snapshot = StrictHidingSnapshot()
		snapshot.update(isEnabled: true, hiddenAppUUIDs: ["first"])
		snapshot.update(isEnabled: true, hiddenAppUUIDs: ["second"])

		XCTAssertFalse(snapshot.hides("first"), "revealing an app must stop hiding it everywhere")
		XCTAssertTrue(snapshot.hides("second"))
	}

	func testSnapshotIsReadableFromAnotherThread() {
		// The whole point of the type: the backup writer and the widget publisher
		// are not views. Reading while the vault updates must not be a data race.
		let snapshot = StrictHidingSnapshot()
		snapshot.update(isEnabled: true, hiddenAppUUIDs: ["vaulted"])

		let reads = expectation(description: "background reads complete")
		reads.expectedFulfillmentCount = 50
		for _ in 0 ..< 50 {
			DispatchQueue.global(qos: .userInitiated).async {
				XCTAssertTrue(snapshot.hides("vaulted"))
				reads.fulfill()
			}
		}
		wait(for: [reads], timeout: 5)
	}
}
