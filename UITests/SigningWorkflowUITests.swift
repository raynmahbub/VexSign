//
//  SigningWorkflowUITests.swift
//  VexSignUITests
//
//  The identity and delivery screens must stay separate on the real UI. These
//  tests exercise navigation, not Apple provisioning or cryptographic signing.
//

import XCTest

final class SigningWorkflowUITests: VexSignUITestCase {
    func testSigningMethodsShowsBothIdentities() {
        app.tabBars.buttons["Settings"].tap()
        tapLabel("Signing Methods")
        waitForNavigationTitle("Signing Methods")

        waitForText("Signing identity · imported certificate")
        waitForText("Signing identity · Apple Account")
        attachScreenshot("signing-identities")
    }

    func testInstallationMethodIsASeparateScreen() {
        app.tabBars.buttons["Settings"].tap()
        tapLabel("Installation Engine")
        waitForNavigationTitle("Installation")

        waitForText("1. Signing identity")
        attachScreenshot("installation-methods")
    }

    func testAppleAccountSelectionDoesNotOpenAContainerChoice() {
        app.tabBars.buttons["Settings"].tap()
        tapLabel("Signing Methods")
        waitForNavigationTitle("Signing Methods")
        waitForText("Signing identity · Apple Account")

        // The identity explanation is present, but the delivery picker belongs to
        // the separate Installation screen only.
        waitForText("Choosing this identity does not select a container. Review the installation method under Settings → Installation.")
        XCTAssertFalse(
            app.staticTexts["Installation method"].exists,
            "Choosing an identity must not switch the delivery screen in place"
        )
        attachScreenshot("identity-delivery-separation")
    }
}
