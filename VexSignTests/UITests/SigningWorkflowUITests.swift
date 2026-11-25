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
        tapIdentifier(UIID.settingsSigning)
        waitForNavigationTitle("Signing Methods")

        waitForText("Signing identity · imported certificate")
        waitForText("Signing identity · Apple Account")
        attachScreenshot("signing-identities")
    }

    func testInstallationMethodIsASeparateScreen() {
        app.tabBars.buttons["Settings"].tap()
        tapIdentifier(UIID.settingsInstallation)
        waitForNavigationTitle("Installation")

        waitForText("1. Signing identity")
        attachScreenshot("installation-methods")
    }

    func testAppleAccountSelectionDoesNotOpenAContainerChoice() {
        app.tabBars.buttons["Settings"].tap()
        tapIdentifier(UIID.settingsSigning)
        waitForNavigationTitle("Signing Methods")
        waitForText("Signing identity · Apple Account")
        // The caption is conditional: it appears only after the identity is chosen.
        tapIdentifier(UIID.freeAppleID)

        // The identity explanation is present, but the delivery picker belongs to
        // the separate Installation screen only.
        XCTAssertTrue(
            app.staticTexts[UIID.identityDelivery].waitForExistence(timeout: 5),
            "Selecting the Apple Account identity must explain that delivery is separate"
        )
        XCTAssertFalse(
            app.staticTexts["Installation method"].exists,
            "Choosing an identity must not switch the delivery screen in place"
        )
        attachScreenshot("identity-delivery-separation")
    }
}
