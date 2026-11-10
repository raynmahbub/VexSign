import XCTest
import SwiftUI
@testable import VexSign

final class DesignSystemTests: XCTestCase {
    func testPreflightReviewRejectsChangedOptionsIdentityAndIssues() {
        let options = Options.defaultOptions
        let snapshot = SigningPreflightSnapshot(options: options, certificateUUID: "reviewed-cert", issues: [])
        XCTAssertTrue(snapshot.matches(options: options, certificateUUID: "reviewed-cert", issues: []))
        XCTAssertFalse(snapshot.matches(options: options, certificateUUID: "replacement-cert", issues: []))
        XCTAssertFalse(snapshot.matches(options: options, certificateUUID: nil, issues: []))
        var changed = options
        changed.removeAppExtensions.toggle()
        XCTAssertFalse(snapshot.matches(options: changed, certificateUUID: "reviewed-cert", issues: []))
        let issue = PreflightIssue("Changed", "A new issue", severity: .blocking)
        XCTAssertFalse(snapshot.matches(options: options, certificateUUID: "reviewed-cert", issues: [issue]))
        let certificateFree = SigningPreflightSnapshot(options: options, certificateUUID: nil, issues: [])
        XCTAssertTrue(certificateFree.matches(options: options, certificateUUID: nil, issues: []))
    }

    func testImportDuplicateMatchingRequiresNonemptyIdentityAndVersion() {
        XCTAssertTrue(ImportDuplicateReview.matches(identifier: "com.example.app", version: "1.0", otherIdentifier: "com.example.app", otherVersion: "1.0"))
        XCTAssertFalse(ImportDuplicateReview.matches(identifier: nil, version: "1.0", otherIdentifier: nil, otherVersion: "1.0"))
        XCTAssertFalse(ImportDuplicateReview.matches(identifier: "", version: "1.0", otherIdentifier: "", otherVersion: "1.0"))
        XCTAssertFalse(ImportDuplicateReview.matches(identifier: "com.example.app", version: nil, otherIdentifier: "com.example.app", otherVersion: nil))
        XCTAssertFalse(ImportDuplicateReview.matches(identifier: "com.example.app", version: "1.0", otherIdentifier: "com.example.app", otherVersion: "2.0"))
    }

    func testTaskReceiptOmitsPrivateMetadataAndRawErrors() {
        let task = UnifiedTask(kind: .sign, title: "PrivateAppName", subtitle: "https://private.example/app", subjectID: "private-subject-id")
        task.phase = .failed
        task.failureStage = .signing
        task.errorText = "password=secret-token /private/var/app/file.p12"
        let receipt = TaskReceipt.report(for: task)
        for privateText in ["PrivateAppName", "private.example", "private-subject-id", "secret-token", "/private/var"] {
            XCTAssertFalse(receipt.contains(privateText))
        }
        XCTAssertTrue(receipt.contains(UnifiedTaskPhase.signing.title))
        task.phase = .completed
        XCTAssertFalse(TaskReceipt.outcome(for: task).isEmpty)
    }

    /// Whether the signed copy is kept is no longer a question a completion action answers: it
    /// always is (`PostSignArtifactsTests`). What is left here is which actions install.
    func testCompletionActionsInstallOnlyWhenAskedTo() {
        XCTAssertFalse(SigningCompletionAction.done.shouldInstall(automaticInstall: false))
        XCTAssertTrue(SigningCompletionAction.install.shouldInstall(automaticInstall: false))
        XCTAssertFalse(SigningCompletionAction.share.shouldInstall(automaticInstall: false))
        XCTAssertFalse(SigningCompletionAction.library.shouldInstall(automaticInstall: false))
        for action in [SigningCompletionAction.done, .install, .share, .library] {
            XCTAssertTrue(action.shouldInstall(automaticInstall: true))
        }
    }

    func testSigningWorkflowMapsRealStages() {
        XCTAssertEqual(SigningWorkspaceStep(stage: .copying), .prepare)
        for stage in [SigningStage.modifying, .thinning, .injecting] {
            XCTAssertEqual(SigningWorkspaceStep(stage: stage), .customize)
        }
        XCTAssertEqual(SigningWorkspaceStep(stage: .signing), .sign)
        XCTAssertEqual(SigningWorkspaceStep(stage: .verifying), .verify)
        XCTAssertEqual(SigningWorkspaceStep(stage: .registering), .verify)
    }

    func testSigningWorkflowNeverInfersInstallationOrSkippedStages() {
        let observed: Set<SigningStage> = [.copying, .signing, .verifying]
        XCTAssertEqual(SigningWorkspaceStep.install.status(reached: observed, current: .verifying,
            running: false, succeeded: true, failed: false, cancelled: false), .separate)
        XCTAssertEqual(SigningWorkspaceStep.customize.status(reached: observed, current: .verifying,
            running: false, succeeded: true, failed: false, cancelled: false), .pending)
        XCTAssertEqual(SigningWorkspaceStep.verify.status(reached: observed, current: .verifying,
            running: false, succeeded: true, failed: false, cancelled: false), .completed)
    }

    func testSigningWorkflowDistinguishesRunningFailureAndCancellation() {
        let observed: Set<SigningStage> = [.copying, .signing]
        XCTAssertEqual(SigningWorkspaceStep.sign.status(reached: observed, current: .signing,
            running: true, succeeded: false, failed: false, cancelled: false), .active)
        XCTAssertEqual(SigningWorkspaceStep.sign.status(reached: observed, current: .signing,
            running: false, succeeded: false, failed: true, cancelled: false), .failed)
        XCTAssertEqual(SigningWorkspaceStep.sign.status(reached: observed, current: .signing,
            running: false, succeeded: false, failed: false, cancelled: true), .cancelled)
        XCTAssertEqual(SigningWorkspaceStep.prepare.status(reached: observed, current: .signing,
            running: false, succeeded: false, failed: true, cancelled: false), .completed)
    }

    func testWorkspaceGreetingBoundaries() {
        XCTAssertEqual(WorkspaceGreeting.title(hour: 0), WorkspaceGreeting.title(hour: 23))
        XCTAssertEqual(WorkspaceGreeting.title(hour: 5), WorkspaceGreeting.title(hour: 11))
        XCTAssertNotEqual(WorkspaceGreeting.title(hour: 4), WorkspaceGreeting.title(hour: 5))
        XCTAssertEqual(WorkspaceGreeting.title(hour: 12), WorkspaceGreeting.title(hour: 17))
        XCTAssertNotEqual(WorkspaceGreeting.title(hour: 11), WorkspaceGreeting.title(hour: 12))
        XCTAssertEqual(WorkspaceGreeting.title(hour: 18), WorkspaceGreeting.title(hour: 23))
    }

    func testActionSizingStacksBeforeLabelsAreCompressed() {
        XCTAssertFalse(WorkspaceActionSizing.shouldStack(idealWidths: [90, 100, 80], availableWidth: 324, spacing: 12, accessibility: false))
        XCTAssertTrue(WorkspaceActionSizing.shouldStack(idealWidths: [90, 100, 80], availableWidth: 323, spacing: 12, accessibility: false))
        XCTAssertTrue(WorkspaceActionSizing.shouldStack(idealWidths: [60, 60], availableWidth: 500, spacing: 12, accessibility: true))
        XCTAssertFalse(WorkspaceActionSizing.shouldStack(idealWidths: [], availableWidth: 0, spacing: 12, accessibility: true))
        XCTAssertTrue(WorkspaceActionSizing.shouldStack(idealWidths: [44], availableWidth: 0, spacing: 12, accessibility: false))
    }

    func testHomeSetupCountsOnlyThreeRealSteps() {
        XCTAssertEqual(VexHomeSetup.completedSteps(certificates: 0, repositories: 0, apps: 0), 0)
        XCTAssertEqual(VexHomeSetup.completedSteps(certificates: 1, repositories: 0, apps: 0), 1)
        XCTAssertEqual(VexHomeSetup.completedSteps(certificates: 1, repositories: 2, apps: 0), 2)
        XCTAssertEqual(VexHomeSetup.completedSteps(certificates: 1, repositories: 1, apps: 3), 3)
        XCTAssertTrue(VexHomeSetup.isComplete(certificates: 1, repositories: 1, apps: 1))
        XCTAssertFalse(VexHomeSetup.isComplete(certificates: 0, repositories: 1, apps: 1))
    }

    func testThemePreservesExistingPreferenceValues() {
        XCTAssertEqual(VexSignVisualTheme(rawValue: "system"), .system)
        XCTAssertEqual(VexSignVisualTheme(rawValue: "luna"), .luna)
        XCTAssertEqual(VexSignVisualTheme(rawValue: "flareWeb"), .flare)
        XCTAssertNil(VexSignVisualTheme.system.preferredColorScheme)
        XCTAssertEqual(VexSignVisualTheme.paper.preferredColorScheme, .light)
        for theme in [VexSignVisualTheme.midnightViolet, .graphite, .oled, .luna, .flare] {
            XCTAssertEqual(theme.preferredColorScheme, .dark)
        }
    }

    func testThemesHaveUniqueStableIDsAndValidAccentColors() {
        XCTAssertEqual(Set(VexSignVisualTheme.allCases.map(\.id)).count, VexSignVisualTheme.allCases.count)
        for theme in VexSignVisualTheme.allCases {
            XCTAssertTrue(theme.defaultAccentHex.hasPrefix("#"))
            XCTAssertEqual(theme.defaultAccentHex.count, 7)
            XCTAssertNotNil(UInt32(theme.defaultAccentHex.dropFirst(), radix: 16))
        }
    }

    func testLibraryAttentionDoesNotTreatMissingEvidenceAsFailure() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertNil(LibraryAttentionReason.evaluate(isSigned: true, expiry: nil, revoked: false, hasUpdate: false, now: now))
        XCTAssertNil(LibraryAttentionReason.evaluate(isSigned: false, expiry: now.addingTimeInterval(-1), revoked: true, hasUpdate: false, now: now))
        XCTAssertEqual(LibraryAttentionReason.evaluate(isSigned: true, expiry: now, revoked: false, hasUpdate: false, now: now), .expired)
        XCTAssertEqual(LibraryAttentionReason.evaluate(isSigned: true, expiry: now.addingTimeInterval(86_400), revoked: false, hasUpdate: false, now: now), .expiringSoon)
        XCTAssertEqual(LibraryAttentionReason.evaluate(isSigned: true, expiry: nil, revoked: true, hasUpdate: true, now: now), .revoked)
        XCTAssertEqual(LibraryAttentionReason.evaluate(isSigned: false, expiry: nil, revoked: false, hasUpdate: true, now: now), .updateAvailable)
    }
}
