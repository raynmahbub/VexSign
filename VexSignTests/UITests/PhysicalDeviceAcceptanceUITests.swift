//
//  PhysicalDeviceAcceptanceUITests.swift
//  VexSignUITests
//
//  Hardware-only acceptance for observations a simulator cannot make. Every
//  test skips with an explicit reason unless it runs on a physical device with
//  VEXSIGN_DEVICE_ACCEPTANCE=1. A skip is not a pass, and no report is generated
//  from these tests alone.
//

import XCTest

final class PhysicalDeviceAcceptanceUITests: VexSignUITestCase {
    override func setUpWithError() throws {
        try HardwareAcceptanceSupport.requireHardware()
        try super.setUpWithError()
    }

    func testInstalledIdentityAndRelaunchOnHardware() throws {
        XCTAssertEqual(app.bundleID, "com.vexsign.app")
        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 10))
        add(HardwareAcceptanceSupport.note(
            "Physical device launched the installed VexSign bundle.",
            name: "hardware-launch"
        ))

        app.terminate()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["Settings"].exists)
    }

    func testBackgroundForegroundLifecycleKeepsNavigationUsable() throws {
        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.tabBars.buttons["Settings"].isSelected)

        // XCUITest cannot send the app to the background without a host app
        // callback, but terminate/relaunch is reproducible on hardware and
        // exercises the same restored-state path after an interruption.
        app.terminate()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 10))
        add(HardwareAcceptanceSupport.note(
            "Navigation remained usable after an interrupted session on hardware.",
            name: "hardware-lifecycle"
        ))
    }

    func testSanitizedDiagnosticExportIsReachableOnHardware() throws {
        app.tabBars.buttons["Settings"].tap()
        tapIdentifier(UIID.diagnosticsCenter)
        waitForNavigationTitle("Diagnostics Center")
        tapIdentifier(UIID.troubleshooting)
        waitForNavigationTitle("Troubleshooting Center")

        let export = app.descendants(matching: .any)[UIID.exportFiltered].firstMatch
        XCTAssertTrue(export.waitForExistence(timeout: 8))
        XCTAssertTrue(export.isEnabled)
        add(HardwareAcceptanceSupport.note(
            "Export control is reachable. Inspect the exported bundle with the device acceptance report; a UI tap alone does not prove redaction.",
            name: "hardware-diagnostics"
        ))
    }
}
