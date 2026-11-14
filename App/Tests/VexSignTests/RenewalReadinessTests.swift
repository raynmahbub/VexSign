import XCTest
@testable import VexSign

final class RenewalReadinessTests: XCTestCase {
    private var available: RenewalReadinessInputs {
        RenewalReadinessInputs(hasLibraryBundle: true, hasSavedSettings: true,
                               savedCertificateUUID: "saved", resolvedCertificateUUID: "saved",
                               hasCertificate: true, certificateExpired: false, certificateRevoked: false)
    }

    func testRetainedInputsAreNotAWorkingRenewalClaim() {
        let report = RenewalReadiness(available)
        XCTAssertTrue(report.retainedInputsAvailable)
        XCTAssertEqual(report.identity, .savedIdentity)
    }

    func testFallbackMustNotClaimContinuity() {
        var inputs = available
        inputs.resolvedCertificateUUID = "other"
        XCTAssertEqual(RenewalReadiness(inputs).identity, .fallback)
        XCTAssertFalse(RenewalReadiness(inputs).retainedInputsAvailable)
    }

    func testUnpinnedSelectionNeedsReview() {
        var inputs = available
        inputs.savedCertificateUUID = nil
        XCTAssertEqual(RenewalReadiness(inputs).identity, .currentSelection)
        XCTAssertFalse(RenewalReadiness(inputs).retainedInputsAvailable)
    }

    func testMissingExpiredRevokedAndRemovedSource() {
        var inputs = available
        inputs.hasCertificate = false
        XCTAssertEqual(RenewalReadiness(inputs).identity, .missing)
        inputs.hasCertificate = true
        inputs.certificateExpired = true
        XCTAssertEqual(RenewalReadiness(inputs).identity, .expired)
        inputs.certificateRevoked = true
        XCTAssertEqual(RenewalReadiness(inputs).identity, .revoked)
        inputs = available
        inputs.hasLibraryBundle = false
        XCTAssertFalse(RenewalReadiness(inputs).retainedInputsAvailable)
        inputs = available
        inputs.hasSavedSettings = false
        XCTAssertFalse(RenewalReadiness(inputs).retainedInputsAvailable)
    }
}
