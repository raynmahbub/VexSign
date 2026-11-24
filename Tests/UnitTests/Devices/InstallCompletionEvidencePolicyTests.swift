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
}
