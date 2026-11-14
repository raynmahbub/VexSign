import XCTest
@testable import VexSign

/// Value-policy tests only. A review constructed here is not Apple trust or a
/// private-key proof; the execution owner independently authenticates its inputs.
final class SigningReadinessTests: XCTestCase {
    private func component(_ status: SigningValidationStatus = .valid, path: String = ".") -> SigningComponentReview {
        .init(id: path, bundleIdentifier: path == "." ? "com.example.app" : "com.example.app.widget",
            status: status, certificateName: "Resolved identity", identityReference: "resolved-row",
            profileName: "Resolved profile", profileUUID: SigningRegressionFixture.profileUUID,
            profileExpiration: SigningRegressionFixture.now, certificateExpiration: SigningRegressionFixture.now,
            team: SigningRegressionFixture.team, deviceAuthorization: "Unit-test evidence only",
            entitlementKeys: [], issues: status == .valid ? [] : ["No compatible profile for the original identifier."])
    }
    private func evidence(components: [SigningComponentReview]? = nil, authenticatedPlan: Bool = true,
                          findings: [BundleExecutableAudit.Finding] = [], notices: [String] = [], removals: [String] = []) -> SigningReviewEvidence {
        let authorization: SigningResolutionAuthorization? = authenticatedPlan
            ? .init(fingerprint: "synthetic-review-binding", plannedRemovals: removals, sourceFingerprint: "synthetic-source-binding") : nil
        return .init(report: .init(inspected: 1, findings: findings), requiredBytes: 1024,
            resolution: .init(components: components ?? [component()], inventoryNotices: notices,
                plannedRemovals: removals, authorization: authorization))
    }
    private func readiness(_ evidence: SigningReviewEvidence? = nil, issues: [PreflightIssue] = [],
                           failure: String? = nil, requiresIdentity: Bool = true) -> SigningReadiness {
        .init(requiresIdentity: requiresIdentity, preflight: .init(issues: issues), evidence: evidence, auditFailure: failure)
    }

    func testInitialAndReplacementInspectionsCannotApprove() {
        for required in [true, false] {
            let value = SigningReadiness.checking(requiresIdentity: required)
            XCTAssertEqual(value.state, .checking)
            XCTAssertFalse(value.canApprove)
            XCTAssertFalse(value.identitiesValidated)
        }
    }

    func testMissingInspectionIsNotACompletedSuccessfulCheckInAnyMode() {
        for required in [true, false] {
            XCTAssertEqual(readiness(requiresIdentity: required).state, .blocked)
            XCTAssertFalse(readiness(requiresIdentity: required).canApprove)
        }
    }

    func testOnlyTheCompletedResolvedPlanCanPassIdentityReadiness() {
        let value = readiness(evidence())
        XCTAssertEqual(value.state, .ready)
        XCTAssertTrue(value.canApprove)
        XCTAssertTrue(value.identitiesValidated)
        XCTAssertEqual(value.resolution?.mainIdentityReference, "resolved-row")
        // No selected-certificate index or display-name comparison participates.
    }

    func testValidLookingComponentsWithoutAnExecutionBindingRemainBlocked() {
        let value = readiness(evidence(authenticatedPlan: false))
        XCTAssertEqual(value.state, .blocked)
        XCTAssertFalse(value.canApprove)
        XCTAssertFalse(value.identitiesValidated)
    }

    func testEveryRetainedComponentMustResolveNotJustTheMainApp() {
        for status in [SigningValidationStatus.invalid, .unsupported, .ambiguous] {
            let value = readiness(evidence(components: [component(), component(status, path: "PlugIns/Widget.appex")]))
            XCTAssertEqual(value.state, .blocked)
            XCTAssertFalse(value.canApprove)
        }
        XCTAssertFalse(readiness(evidence(components: [])).canApprove)
    }

    func testScreenshotProfileMismatchCannotLeaveTheActionEnabled() {
        let mismatch = PreflightIssue("Profile does not cover this app", "Import a profile for com.example.app.",
            severity: .blocking, code: .appIdentifierMismatch)
        let value = readiness(evidence(), issues: [mismatch])
        XCTAssertEqual(value.state, .blocked)
        XCTAssertFalse(value.canApprove)
        XCTAssertFalse(value.preflight.canSignAnyway)
        XCTAssertEqual(value.preflight.issues.first?.detail, "Import a profile for com.example.app.")
    }

    func testEveryMandatoryPreflightCodeBlocksEvenWhenTheComponentPlanIsValid() {
        for code in SigningCapability.Issue.Code.allCases where code.isMandatory {
            let value = readiness(evidence(), issues: [.init("Mandatory", "Cannot bypass", severity: .blocking, code: code)])
            XCTAssertFalse(value.canApprove, code.rawValue)
            XCTAssertFalse(value.preflight.canSignAnyway, code.rawValue)
        }
    }

    func testAnyBlockingExecutableFindingKeepsTheWholeWorkflowBlocked() {
        let value = readiness(evidence(findings: [.init(path: "Frameworks/Unreadable.framework", problem: .unreadable)]))
        XCTAssertEqual(value.state, .blocked)
        XCTAssertFalse(value.canApprove)
    }

    func testInspectionFailureCannotReusePreviouslyGoodIdentityEvidence() {
        let value = readiness(evidence(), failure: "Identity input changed during inspection")
        XCTAssertEqual(value.state, .blocked)
        XCTAssertFalse(value.canApprove)
    }

    func testNonmandatoryRisksRemainWarningsAndStillRequireReviewConfirmation() {
        let value = readiness(evidence(), issues: [.init("Risk", "A user-overridable risk", severity: .blocking, code: .general)])
        XCTAssertEqual(value.state, .warning)
        XCTAssertTrue(value.canApprove)
        XCTAssertTrue(value.preflight.canSignAnyway)
        XCTAssertEqual(value.warningCount, 1)
    }

    func testInventoryNoticesAndExplicitRemovalsAreVisibleWarningsNotSilentChanges() {
        let value = readiness(evidence(notices: ["Another imported profile was rejected"], removals: ["PlugIns/Share.appex"]))
        XCTAssertEqual(value.state, .warning)
        XCTAssertEqual(value.warningCount, 2)
        XCTAssertEqual(value.resolution?.authorization?.plannedRemovals, ["PlugIns/Share.appex"])
    }

    func testModifyOnlyCanBeReadyWithoutPretendingAnIdentityWasValidated() {
        let value = readiness(.init(report: .init(inspected: 0, findings: []), requiredBytes: 0), requiresIdentity: false)
        XCTAssertEqual(value.state, .ready)
        XCTAssertTrue(value.canApprove)
        XCTAssertFalse(value.identitiesValidated)
    }
}
