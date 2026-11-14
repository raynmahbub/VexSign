//
//  AutomationAvailabilityTests.swift
//  VexSignTests
//
//  A Shortcut used to answer "Everything is up to date." for a pass that never started, because
//  `BackgroundAutomation.run` returns nil for five different reasons. These tests pin the two
//  rules that replaced it: a blocked pass names its blocker, and a finished pass reports its
//  failures next to its successes instead of instead of them.
//
//  Both rules are pure functions of values the caller already has, so nothing here needs a run,
//  a source, a certificate or a device.
//

import XCTest
import NimbleExtensions
@testable import VexSign

final class AutomationAvailabilityTests: XCTestCase {
    // MARK: - Blockers

    func testDisabledWinsOverEveryOtherCondition() {
        XCTAssertEqual(
            AutomationAvailability.blocker(enabled: false, running: true, gameMode: true, updateAllRunning: true),
            .disabled
        )
    }

    func testBusyCoversBothRunningPasses() {
        XCTAssertEqual(
            AutomationAvailability.blocker(enabled: true, running: true, gameMode: false, updateAllRunning: false),
            .busy
        )
        XCTAssertEqual(
            AutomationAvailability.blocker(enabled: true, running: false, gameMode: false, updateAllRunning: true),
            .busy
        )
    }

    func testGameModeIsABlockerOfItsOwn() {
        XCTAssertEqual(
            AutomationAvailability.blocker(enabled: true, running: false, gameMode: true, updateAllRunning: false),
            .gameMode
        )
    }

    func testAnAvailablePassHasNoBlocker() {
        XCTAssertNil(AutomationAvailability.blocker(enabled: true, running: false, gameMode: false, updateAllRunning: false))
    }

    func testEveryBlockerExplainsItselfWithoutClaimingSuccess() {
        for blocker in AutomationAvailability.Blocker.allCases {
            let message = AutomationAvailability.message(for: blocker)
            XCTAssertFalse(message.isEmpty, "\(blocker) has no message")
            XCTAssertFalse(
                message.localizedCaseInsensitiveContains("up to date"),
                "\(blocker) must not claim the library was checked: \(message)"
            )
        }
    }

    // MARK: - Dialogue

    func testABlockedPassNeverReportsUpToDate() {
        // The regression this file exists for.
        for blocker in AutomationAvailability.Blocker.allCases {
            let message = AutomationDialogue.message(found: 0, signed: 0, blocked: blocker)
            XCTAssertEqual(message, AutomationAvailability.message(for: blocker))
            XCTAssertFalse(message.localizedCaseInsensitiveContains("up to date"))
        }
    }

    func testAnEmptyPassReportsUpToDate() {
        XCTAssertEqual(
            AutomationDialogue.message(found: 0, signed: 0),
            .localized("Everything is up to date.")
        )
    }

    func testUpdatesWithoutSigningAskForTheSetting() {
        // Signed stays zero when "Sign & queue" is off; the message has to name the setting
        // rather than implying the updates were handled.
        let message = AutomationDialogue.message(found: 3, signed: 0)
        XCTAssertTrue(message.contains("3"))
        XCTAssertFalse(message.localizedCaseInsensitiveContains("signed and queued"))
    }

    func testSignedCountIsReported() {
        XCTAssertEqual(
            AutomationDialogue.message(found: 3, signed: 2),
            String.localized("%lld apps signed and queued for install.", arguments: 2)
        )
    }

    func testFailuresAreReportedNextToSuccesses() {
        let message = AutomationDialogue.message(found: 3, signed: 2, failed: 1)
        XCTAssertTrue(message.hasPrefix(String.localized("%lld apps signed and queued for install.", arguments: 2)))
        XCTAssertTrue(message.contains(String.localized("%lld operations could not be completed.", arguments: 1)))
    }

    func testAFailedPassWithNoUpdatesDoesNotClaimUpToDate() {
        let message = AutomationDialogue.message(found: 0, signed: 0, failed: 2)
        XCTAssertFalse(message.localizedCaseInsensitiveContains("up to date"))
        XCTAssertTrue(message.contains(String.localized("%lld operations could not be completed.", arguments: 2)))
    }

    func testAnUnfinishedPassClaimsNothing() {
        let message = AutomationDialogue.unfinished
        XCTAssertFalse(message.localizedCaseInsensitiveContains("up to date"))
        XCTAssertFalse(message.localizedCaseInsensitiveContains("signed"))
    }
}
