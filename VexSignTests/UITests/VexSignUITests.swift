//
//  VexSignUITests.swift
//  VexSignUITests
//
//  Launch, navigation and app lifecycle smoke tests on a real screen.
//

import XCTest

final class VexSignUITests: VexSignUITestCase {
    func testLaunchShowsMainNavigation() {
        XCTAssertTrue(app.tabBars.firstMatch.exists, "The main tab bar should be visible after launch")
        XCTAssertTrue(app.tabBars.buttons["Library"].exists)
        XCTAssertTrue(app.tabBars.buttons["Settings"].exists)
        attachScreenshot("launch-navigation")
    }

    func testNavigateBetweenMainTabs() {
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.tabBars.buttons["Library"].isSelected)

        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.tabBars.buttons["Settings"].isSelected)
        attachScreenshot("settings-tab")
    }

    func testSelectedTabSurvivesRelaunch() {
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.tabBars.buttons["Settings"].isSelected)
        app.terminate()

        app.launch()
        XCTAssertTrue(
            app.tabBars.buttons["Settings"].waitForExistence(timeout: 5),
            "The app should relaunch after termination"
        )
        attachScreenshot("relaunch")
    }

    func testLibraryOpensContainerWorkspace() {
        app.tabBars.buttons["Library"].tap()
        let containers = app.buttons[UIID.libraryContainers].firstMatch
        XCTAssertTrue(containers.waitForExistence(timeout: 5), "The container toolbar action should be reachable")
        containers.tap()
        XCTAssertTrue(app.navigationBars["Containers"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Managed Containers"].exists)
        attachScreenshot("container-workspace")
    }

    func testSettingsReachesDeviceLifecycleEntry() {
        app.tabBars.buttons["Settings"].tap()
        let updates = app.staticTexts["App Updates"].firstMatch
        XCTAssertTrue(updates.waitForExistence(timeout: 5), "The App Updates row should be reachable")
        updates.tap()
        let bootstrap = app.staticTexts["Review bootstrap limitations"].firstMatch
        XCTAssertTrue(bootstrap.waitForExistence(timeout: 5))
        bootstrap.tap()
        let entry = app.descendants(matching: .any)["device.lifecycle.entry"].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "The lifecycle entry should be visible in Tunnel")
        attachScreenshot("device-lifecycle-entry")
    }

    /// Navigation only. It does not request notification permission or claim
    /// that a simulated launch proves local delivery.
    func testSettingsReachesNotificationPreferences() {
        app.tabBars.buttons["Settings"].tap()
        let notifications = app.staticTexts["Notifications & Live Activities"].firstMatch
        XCTAssertTrue(notifications.waitForExistence(timeout: 5))
        notifications.tap()
        let types = app.staticTexts["VexSign notification types and reminders"].firstMatch
        XCTAssertTrue(types.waitForExistence(timeout: 5))
        types.tap()
        XCTAssertTrue(app.navigationBars["Notification Types"].waitForExistence(timeout: 5))
        attachScreenshot("notification-preferences")
    }

    func testLibrarySwipeGestureIsSafe() {
        app.tabBars.buttons["Library"].tap()
        let firstCell = app.cells.firstMatch
        if firstCell.waitForExistence(timeout: 3) {
            firstCell.swipeLeft()
            XCTAssertTrue(app.exists, "A swipe must not terminate the app")
        }
        attachScreenshot("library-gesture")
    }
}
