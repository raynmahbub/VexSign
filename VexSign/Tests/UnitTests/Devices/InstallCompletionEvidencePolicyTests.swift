import XCTest
@testable import VexSign

final class InstallCompletionEvidencePolicyTests: XCTestCase {
    private let afterAcknowledgement = InstallationEvidenceTestFixtures.epoch.addingTimeInterval(3)

    func testOTATransportOrPrivateObservationCannotBePromotedByPairedEvidence() {
        let method = InstallationEvidenceMethod(code: "OTA")
        XCTAssertEqual(method, .ota)
        XCTAssertFalse(InstallCompletionEvidencePolicy.allowsInstalledOutcome(
            method: method, hasExactPairedDeviceEvidence: true
        ), "OTA has no supported general installed-app inventory in the sandbox")
        XCTAssertEqual(method.rejectedInstalledReason, "ota-completion-not-authoritative")

        var otaContext = InstallationEvidenceTestFixtures.context()
        otaContext.installationMethod = "OTA"
        XCTAssertFalse(otaContext.hasConfirmedInstallation(notAfter: afterAcknowledgement),
                       "Paired-device evidence must not confirm a task recorded as OTA")
    }

    func testPairedDeviceCompletionRequiresTheCompleteDatedEvidenceContext() {
        let method = InstallationEvidenceMethod(code: "paired-device")
        XCTAssertEqual(method, .pairedDevice)
        XCTAssertTrue(InstallCompletionEvidencePolicy.allowsInstalledOutcome(
            method: method, hasExactPairedDeviceEvidence: true
        ))
        XCTAssertTrue(InstallationEvidenceTestFixtures.context().hasConfirmedInstallation(notAfter: afterAcknowledgement))

        XCTAssertFalse(InstallCompletionEvidencePolicy.allowsInstalledOutcome(
            method: method, hasExactPairedDeviceEvidence: false
        ))
        var missingProof = InstallationEvidenceTestFixtures.context()
        missingProof.installedApplicationEvidence = nil
        XCTAssertFalse(missingProof.hasConfirmedInstallation(notAfter: afterAcknowledgement))
        missingProof = InstallationEvidenceTestFixtures.context()
        missingProof.confirmationReason = "native-installation-completed"
        XCTAssertFalse(missingProof.hasConfirmedInstallation(notAfter: afterAcknowledgement),
                       "A native command acknowledgement is not exact installed-version evidence")
    }

    func testExportGuestAndUnknownRoutesNeverClaimDeviceInstallation() {
        for code in ["export", "guest-import", "unexpected-route", nil] {
            let method = InstallationEvidenceMethod(code: code)
            XCTAssertFalse(InstallCompletionEvidencePolicy.allowsInstalledOutcome(
                method: method, hasExactPairedDeviceEvidence: true
            ), "\(code ?? "nil") must not be treated as an install-capable route")
        }
        XCTAssertEqual(InstallationEvidenceMethod(code: "unexpected-route"), .unresolved)
        XCTAssertEqual(InstallationEvidenceMethod(code: nil).rejectedInstalledReason,
                       "installation-evidence-unavailable")
    }

    func testLifecycleDistinguishesSubmittedInstallingConfirmedAndUnconfirmed() {
        XCTAssertEqual(
            InstallCompletionEvidencePolicy.lifecycleStage(
                method: .ota,
                hasHandedOff: true,
                isInstalling: false,
                hasExactPairedDeviceEvidence: false,
                isTerminal: false
            ),
            .submitted
        )
        XCTAssertEqual(
            InstallCompletionEvidencePolicy.lifecycleStage(
                method: .ota,
                hasHandedOff: true,
                isInstalling: true,
                hasExactPairedDeviceEvidence: false,
                isTerminal: false
            ),
            .installing
        )
        XCTAssertEqual(
            InstallCompletionEvidencePolicy.lifecycleStage(
                method: .ota,
                hasHandedOff: true,
                isInstalling: false,
                hasExactPairedDeviceEvidence: true,
                isTerminal: true
            ),
            .unconfirmed,
            "OTA must remain unconfirmed even when terminal or paired evidence is passed."
        )
        XCTAssertEqual(
            InstallCompletionEvidencePolicy.lifecycleStage(
                method: .pairedDevice,
                hasHandedOff: true,
                isInstalling: false,
                hasExactPairedDeviceEvidence: true,
                isTerminal: true
            ),
            .confirmed
        )
        XCTAssertEqual(
            InstallCompletionEvidencePolicy.lifecycleStage(
                method: .pairedDevice,
                hasHandedOff: true,
                isInstalling: false,
                hasExactPairedDeviceEvidence: false,
                isTerminal: true
            ),
            .unconfirmed,
            "Paired device disconnect/timeout without exact installed-version readback must stay unconfirmed."
        )
    }

    func testUnconfirmedInstallPreservesManualVerificationAndRefusesAutoRetry() {
        XCTAssertTrue(InstallCompletionEvidencePolicy.preservesManualVerificationRecovery(stage: .unconfirmed))
        XCTAssertFalse(InstallCompletionEvidencePolicy.allowsAutomaticRetry(stage: .unconfirmed))
        XCTAssertFalse(InstallRetryPolicy.allowsAutomaticRetry(outcomeUnknown: true))

        XCTAssertEqual(
            InstallRetryPolicy.refusal(
                signedCopyPresent: true,
                duplicateInFlight: false,
                outcomeUnknown: true,
                afterManualDeviceCheck: false
            ),
            .checkDeviceFirst
        )
        XCTAssertNil(
            InstallRetryPolicy.refusal(
                signedCopyPresent: true,
                duplicateInFlight: false,
                outcomeUnknown: true,
                afterManualDeviceCheck: true
            ),
            "Explicit manual device verification must unlock retry recovery."
        )
    }

    func testExportCompletionIsDistinctFromInstallationCompletion() {
        let exported = InstallQueue.InstallOutcome.exported
        XCTAssertNotEqual(exported, .succeeded)
        XCTAssertFalse(exported.canOpenApp(isExport: true, identifier: "com.example.app"))
        XCTAssertFalse(exported.canOpenApp(isExport: false, identifier: "com.example.app"))
        XCTAssertFalse(InstallQueue.canSkip(outcome: .exported, hasFailure: false))

        let presentation = InstallPresentation.resolve(
            status: .completed(.success(())),
            phase: .waitingForStart,
            taskPhase: nil,
            isExport: true
        )
        XCTAssertEqual(presentation, .operationCompleted)
        XCTAssertNotEqual(presentation, .installed)

        let evidence = InstallEvidenceSummary.resolve(method: "export", reason: nil, handedOff: false)
        XCTAssertEqual(evidence.transport, .export)
        XCTAssertEqual(evidence.confirmation, .notApplicable)
        XCTAssertNotEqual(evidence.lifecycleStage, .confirmed)
    }

    func testStoppingMonitoringAfterHandoffEndsUnconfirmedWhileBeforeHandoffEndsCancelled() {
        XCTAssertEqual(InstallQueue.phaseAfterStoppingMonitoring(hasHandedOff: true), .unconfirmed)
        XCTAssertEqual(InstallQueue.phaseAfterStoppingMonitoring(hasHandedOff: false), .cancelled)
    }
}
