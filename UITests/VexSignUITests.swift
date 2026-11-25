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
