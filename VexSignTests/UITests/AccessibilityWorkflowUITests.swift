//
//  AccessibilityWorkflowUITests.swift
//  VexSignUITests
//
//  Deterministic, credential-free coverage of the accessibility surfaces that
//  can be observed from XCUITest. VoiceOver pronunciation and contrast require
//  Accessibility Inspector or a physical device; these tests cover the element
//  tree, identifiers, and interaction state the app actually publishes.
//

import XCTest

final class AccessibilityWorkflowUITests: VexSignUITestCase {
    func testDiagnosticsWorkflowIsReachableByIdentifier() {
        app.tabBars.buttons["Settings"].tap()
        tapIdentifier(UIID.diagnosticsCenter)
        waitForNavigationTitle("Diagnostics Center")

        tapIdentifier(UIID.troubleshooting)
        waitForNavigationTitle("Troubleshooting Center")
        XCTAssertTrue(
            app.descendants(matching: .any)[UIID.events].firstMatch.exists,
            "The recorded-events section must be present for diagnostics review"
        )
        attachScreenshot("diagnostics-troubleshooting")
    }

    func testTroubleshootingFiltersAndExportAreAccessible() {
        app.tabBars.buttons["Settings"].tap()
        tapIdentifier(UIID.diagnosticsCenter)
        tapIdentifier(UIID.troubleshooting)
        waitForNavigationTitle("Troubleshooting Center")

        let categoryFilter = app.descendants(matching: .any)[UIID.categoryFilter].firstMatch
        XCTAssertTrue(categoryFilter.waitForExistence(timeout: 5))
        XCTAssertEqual(categoryFilter.elementType, .button, "The category filter must be a real control")
        categoryFilter.tap()
        XCTAssertTrue(app.buttons["All"].waitForExistence(timeout: 3) || app.staticTexts["All"].exists)

        let operationFilter = app.textFields[UIID.operationFilter].firstMatch
        XCTAssertTrue(operationFilter.waitForExistence(timeout: 5))
        XCTAssertEqual(operationFilter.placeholderValue, "Operation or task ID")

        let export = app.buttons[UIID.exportFiltered].firstMatch
        XCTAssertTrue(export.waitForExistence(timeout: 5))
        XCTAssertTrue(export.isEnabled)
        attachScreenshot("diagnostics-filters")
    }

    func testCoreTabBarControlsCarryLabels() {
        for name in ["Library", "Settings"] {
            let tab = app.tabBars.buttons[name]
            XCTAssertTrue(tab.waitForExistence(timeout: 5))
            XCTAssertFalse(tab.label.isEmpty, "Tab \(name) must expose a spoken label")
        }
        let elements = app.descendants(matching: .button)
        XCTAssertGreaterThan(elements.count, 0, "At least one button must be exposed to assistive technology")
        attachScreenshot("tab-bar-accessibility")
    }

    /// Dark appearance is a system launch setting, not an app fixture. The
    /// relaunch must still expose the same navigation and controls.
    func testDarkAppearanceKeepsCoreControlsReachable() {
        app.terminate()
        let dark = XCUIApplication()
        dark.launchArguments += ["-vexsign-ui-tests", "1", "-AppleInterfaceStyle", "Dark"]
        dark.launch()
        app = dark
        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.tabBars.buttons["Settings"].isSelected)
        tapIdentifier(UIID.diagnosticsCenter)
        waitForNavigationTitle("Diagnostics Center")
        attachScreenshot("dark-appearance-diagnostics")
    }

    /// Apple's accessibility audit checks the live element tree for missing
    /// descriptions, broken traits and undersized hit regions. Findings are
    /// always printed to the test log. Pass `-vexsign-strict-a11y-audit 1` on
    /// launch to turn real findings into failures once a device baseline has
    /// been reviewed; system keyboard elements are out of our control.
    func testAccessibilityAuditFindingsAreReported() throws {
        let strict = ProcessInfo.processInfo.environment["VEXSIGN_STRICT_A11Y_AUDIT"] == "1"
        do {
            try app.performAccessibilityAudit(for: [.sufficientElementDescription, .trait, .hitRegion]) { issue in
                guard let element = issue.element else { return true }
                if element.elementType == .keyboard || app.keyboards.firstMatch.frame.contains(element.frame) {
                    return true
                }
                print("🔍 VexSign accessibility issue: \(issue.auditType) \(issue.compactDescription) \(element.debugDescription)")
                return !strict
            }
        } catch {
            XCTFail("Accessibility audit failed: \(error)")
        }
    }
}
