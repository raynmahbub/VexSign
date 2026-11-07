//
//  SelfUpdateNotificationTests.swift
//  VexSignTests
//
//  The release notification is the only unprompted thing the updater says, so the rules that
//  decide when it fires are pinned here: once per version, never for a skipped version, never
//  without permission, and never on top of the launch prompt that is already showing it.
//

import Foundation
import UserNotifications
import XCTest
@testable import VexSign

final class SelfUpdateNotificationTests: XCTestCase {
	private func decide(
		version: String = "1.4.0",
		enabled: Bool = true,
		authorization: UNAuthorizationStatus = .authorized,
		notified: Set<String> = [],
		ignored: Set<String> = [],
		surfaced: Set<String> = [],
		active: Bool = false
	) -> Bool {
		SelfUpdateNotifier.shouldNotify(
			version: version,
			isEnabled: enabled,
			authorization: authorization,
			alreadyNotified: notified,
			ignored: ignored,
			alreadySurfaced: surfaced,
			isAppActive: active
		)
	}

	// MARK: - The plain case

	func testAnAllowedNewerReleaseInTheBackgroundIsAnnounced() {
		XCTAssertTrue(decide())
	}

	func testProvisionalAuthorizationCounts() {
		XCTAssertTrue(decide(authorization: .provisional))
	}

	// MARK: - Permission and preference

	func testDisabledSwitchIsSilent() {
		XCTAssertFalse(decide(enabled: false))
	}

	func testUndeterminedPermissionIsNotAReasonToAskFromABackgroundCheck() {
		XCTAssertFalse(decide(authorization: .notDetermined))
	}

	func testDeniedPermissionIsSilent() {
		XCTAssertFalse(decide(authorization: .denied))
	}

	// MARK: - Once per version

	func testAnAlreadyAnnouncedVersionIsNotRepeated() {
		XCTAssertFalse(decide(notified: ["1.4.0"]))
	}

	func testAnotherVersionIsStillAnnounced() {
		XCTAssertTrue(decide(notified: ["1.3.0"]))
	}

	func testAnIgnoredVersionIsNotNews() {
		XCTAssertFalse(decide(ignored: ["1.4.0"]))
	}

	// MARK: - Prompt versus notification

	func testForegroundBeforeThePromptIsSurfacedStaysQuiet() {
		XCTAssertFalse(decide(active: true), "The launch prompt is about to show this release")
	}

	func testForegroundAfterThePromptWasSurfacedDoesAnnounce() {
		XCTAssertTrue(decide(active: true, surfaced: ["1.4.0"]), "A dismissed prompt deserves a reminder")
	}

	func testBackgroundAnnouncesEvenWhenThePromptWasSurfacedBefore() {
		XCTAssertTrue(decide(surfaced: ["1.4.0"]))
	}

	// MARK: - Degenerate input

	func testAnEmptyVersionIsNeverAnnounced() {
		XCTAssertFalse(decide(version: "  "))
	}

	// MARK: - Remembered versions

	func testRememberingKeepsOrderAndDropsDuplicates() {
		XCTAssertEqual(SelfUpdateNotifier.remembering("1.4.0", in: ["1.2.0", "1.4.0"]), ["1.2.0", "1.4.0"])
		XCTAssertEqual(SelfUpdateNotifier.remembering("1.4.0", in: ["1.2.0"]), ["1.2.0", "1.4.0"])
	}

	func testRememberingIsBounded() {
		let many = (0..<SelfUpdateNotifier.maximumRemembered).map { "1.0.\($0)" }
		let updated = SelfUpdateNotifier.remembering("2.0.0", in: many)
		XCTAssertEqual(updated.count, SelfUpdateNotifier.maximumRemembered)
		XCTAssertEqual(updated.last, "2.0.0")
		XCTAssertFalse(updated.contains("1.0.0"), "The oldest entry is the one dropped")
	}

	// MARK: - Tap routing

	func testOnlyReleaseIdentifiersOpenTheUpdateSheet() {
		XCTAssertTrue(SelfUpdateNotifier.isReleaseNotification("vexsign.release.1.4.0"))
		XCTAssertFalse(SelfUpdateNotifier.isReleaseNotification("vexsign.download.finished"))
		XCTAssertFalse(SelfUpdateNotifier.isReleaseNotification("merged_download_progress"))
	}
}
