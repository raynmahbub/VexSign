//
//  InstallationWorkflowUITests.swift
//  VexSignUITests
//
//  Import and installation entry points visible on a real device screen.
//  Actual signing and installation outcomes remain device observations in the
//  feature-acceptance report; a UI test cannot assert iOS accepted an install.
//

import XCTest

final class InstallationWorkflowUITests: VexSignUITestCase {
    func testHomeShowsImportAction() {
        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(app.buttons[UIID.homeImport].waitForExistence(timeout: 5))
        attachScreenshot("home-import")
    }

    func testTasksShowsImportFromFiles() {
        app.tabBars.buttons["Tasks"].tap()
        XCTAssertTrue(
            app.staticTexts["Downloads"].firstMatch.waitForExistence(timeout: 5),
            "The Tasks workspace should open on Downloads"
        )

        // Do not invoke the file picker: prove the entry point is reachable.
        let options = app.buttons[UIID.tasksOptions]
        XCTAssertTrue(options.waitForExistence(timeout: 5), "Download toolbar menu is missing")
        options.tap()
        XCTAssertTrue(
            app.buttons[UIID.tasksImportFiles].waitForExistence(timeout: 5),
            "The Tasks workspace should expose an import action"
        )
        attachScreenshot("tasks-import")
    }

    func testLibraryTabIsAvailableForInstalledApps() {
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.tabBars.buttons["Library"].isSelected)
        attachScreenshot("library")
    }
}
