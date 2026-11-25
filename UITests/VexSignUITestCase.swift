//
//  VexSignUITestCase.swift
//  VexSignUITests
//
//  Shared launch and evidence helpers. Every UI test attaches a screenshot so a
//  failure arrives with the screen the runner actually saw, not only an assertion.
//

import XCTest

class VexSignUITestCase: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-vexsign-ui-tests", "1"]
        app.launch()
    }

    override func tearDownWithError() throws {
        // Keep a final frame even when an assertion stopped the test early.
        // A failing XCUITest without the screen that caused it is not evidence.
        if let app, app.exists {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "final-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        app = nil
    }

    func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// SwiftUI NavigationLinks are not always exposed as buttons, and Settings
    /// rows may be below the fold. Try both element types while scrolling.
    func tapLabel(_ label: String, timeout: TimeInterval = 12,
                  file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let button = app.buttons[label].firstMatch
            if button.exists && button.isHittable {
                button.tap()
                return
            }
            let cell = app.cells.containing(.staticText, identifier: label).firstMatch
            if cell.exists && cell.isHittable {
                cell.tap()
                return
            }
            let scroll = app.scrollViews.firstMatch
            guard scroll.exists, scroll.isHittable else { break }
            scroll.swipeUp()
        }
        XCTFail("No tappable element labelled \(label)", file: file, line: line)
    }

    /// SwiftUI lists recycle off-screen rows. Scroll before declaring a label
    /// missing, but keep a bounded deadline so a broken screen still fails.
    func waitForText(_ text: String, timeout: TimeInterval = 8,
                     file: StaticString = #filePath, line: UInt = #line) {
        let element = app.staticTexts[text].firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists || element.waitForExistence(timeout: 1) { return }
            let scroll = app.scrollViews.firstMatch
            guard scroll.exists, scroll.isHittable else { break }
            scroll.swipeUp()
        }
        XCTFail("Expected text '\(text)' was not visible", file: file, line: line)
    }

    func waitForNavigationTitle(_ title: String, timeout: TimeInterval = 5,
                                file: StaticString = #filePath, line: UInt = #line) {
        let bar = app.navigationBars[title].firstMatch
        XCTAssertTrue(
            bar.waitForExistence(timeout: timeout),
            "Expected screen '\(title)' was not shown",
            file: file, line: line
        )
    }
}
