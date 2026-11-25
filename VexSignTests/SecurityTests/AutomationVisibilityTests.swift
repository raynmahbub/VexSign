//
//  AutomationVisibilityTests.swift
//  VexSignTests
//
//  The Hidden Apps Vault is opened with the device owner's biometrics inside the
//  app. Every surface without that prompt — the Web Manager's routes and the
//  Shortcuts picker — asks this one predicate, so hiding an app cannot hold on
//  one surface and leak on another.
//

import XCTest
@testable import VexSign

final class AutomationVisibilityTests: XCTestCase {

	func testAVaultedAppIsInvisible() {
		XCTAssertFalse(AutomationVisibility.isVisible(uuid: "vaulted", hiddenAppUUIDs: ["vaulted"]))
	}

	func testEveryOtherAppStaysVisible() {
		XCTAssertTrue(AutomationVisibility.isVisible(uuid: "ordinary", hiddenAppUUIDs: ["vaulted"]))
		XCTAssertTrue(AutomationVisibility.isVisible(uuid: "ordinary", hiddenAppUUIDs: []))
	}

	func testARowWithoutAnIdentityCannotBeHidden() {
		// Failing closed here would hide unrelated apps from their owner.
		XCTAssertTrue(AutomationVisibility.isVisible(uuid: nil, hiddenAppUUIDs: ["vaulted"]))
		XCTAssertTrue(AutomationVisibility.isVisible(uuid: "", hiddenAppUUIDs: ["vaulted"]))
	}

	func testTheWebManagerPolicyAndTheShortcutsQueryAgree() {
		// Both wrappers must answer the same question; the template below is the one
		// the routes and the entity query both call.
		let hidden: Set<String> = ["vaulted"]
		for uuid in ["vaulted", "ordinary"] as [String?] {
			XCTAssertEqual(
				AutomationVisibility.isVisible(uuid: uuid, hiddenAppUUIDs: hidden),
				WebManagerAccessPolicy.isVisibleToAutomation(uuid: uuid, hiddenAppUUIDs: hidden),
				"the shared rule and the Web Manager policy drifted for \(uuid ?? "nil")"
			)
		}
	}
}
