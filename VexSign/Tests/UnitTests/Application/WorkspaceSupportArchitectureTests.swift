import Foundation
import XCTest
@testable import VexSign

@MainActor
final class WorkspaceSupportArchitectureTests: XCTestCase {

    @MainActor
    private final class MockPlatform: PlatformSystemAdapting {
        var openedURLs: [URL] = []

        func openExternalURL(_ url: URL) { openedURLs.append(url) }
        func pasteboardString() -> String? { nil }
        func dismissKeyboard() {}
        func restartOrSuspendApp() {}
        func shareItems(_ items: [Any]) {}
        func notifySuccess(_ message: String, systemImage: String) {}
        func notifyInfo(_ message: String, systemImage: String) {}
        func notifyError(_ message: String, sticky: Bool) {}
        func presentDestructiveConfirmation(title: String, message: String, onConfirm: @escaping () -> Void) { onConfirm() }
        func presentYesNoAlert(title: String, message: String, confirmTitle: String, onConfirm: @escaping () -> Void) { onConfirm() }
        func presentErrorWithCopy(title: String, message: String) {}
        func triggerHapticFeedback(success: Bool) {}
    }

    @MainActor
    private final class MockEnvironment: WorkspaceSupportEnvironmentProviding {
        var snapshot = WorkspaceSupportSnapshot(
            deviceModel: "iPhone16,1",
            systemVersion: "26.3",
            appVersion: "1.2.3",
            routingPreference: "automatic",
            installationDetails: [
                "- Install method: `Server`",
                "  - Server type: `Fully Local`"
            ]
        )
        var documentsURL = URL(string: "shareddocuments://documents")
        var archivesURL = URL(string: "shareddocuments://archives")
        var certificatesURL = URL(string: "shareddocuments://certificates")
        var feedbackTitle: String?
        var bugTitle: String?
        var otherTitle: String?
        var bugHandler: (() -> Void)?
        var otherHandler: (() -> Void)?

        func supportSnapshot() -> WorkspaceSupportSnapshot { snapshot }

        func sharedDocumentsURL() -> URL? { documentsURL }
        func sharedArchivesURL() -> URL? { archivesURL }
        func sharedCertificatesURL() -> URL? { certificatesURL }

        func presentFeedbackOptions(
            title: String,
            message: String?,
            bugTitle: String,
            otherTitle: String,
            onBugReport: @escaping () -> Void,
            onOther: @escaping () -> Void
        ) {
            feedbackTitle = title
            self.bugTitle = bugTitle
            self.otherTitle = otherTitle
            bugHandler = onBugReport
            otherHandler = onOther
        }
    }

    func testIssueURLUsesInjectedSnapshotAndNeverIncludesSecrets() {
        let platform = MockPlatform()
        let environment = MockEnvironment()
        let useCase = WorkspaceSupportUseCase(platform: platform, environment: environment)

        let url = useCase.makeGitHubIssueURL()

        XCTAssertTrue(url.contains("issues/new?template=bug.yml"))
        XCTAssertTrue(url.contains("iPhone16,1"))
        XCTAssertTrue(url.contains("26.3"))
        XCTAssertTrue(url.contains("1.2.3"))
        XCTAssertTrue(url.contains("automatic"))
        XCTAssertTrue(url.contains("Fully%20Local") || url.contains("Fully Local"))
        XCTAssertFalse(url.localizedCaseInsensitiveContains("password"))
        XCTAssertFalse(url.localizedCaseInsensitiveContains("privatekey"))
        XCTAssertFalse(url.localizedCaseInsensitiveContains("udid"))
        XCTAssertFalse(url.localizedCaseInsensitiveContains("token"))
    }

    func testFeedbackChoicesOpenTheExpectedSupportURLs() {
        let platform = MockPlatform()
        let environment = MockEnvironment()
        let useCase = WorkspaceSupportUseCase(platform: platform, environment: environment)

        useCase.presentFeedbackSheet()
        XCTAssertFalse((environment.feedbackTitle ?? "").isEmpty)
        XCTAssertFalse((environment.bugTitle ?? "").isEmpty)
        XCTAssertFalse((environment.otherTitle ?? "").isEmpty)

        environment.bugHandler?()
        XCTAssertEqual(platform.openedURLs.last?.absoluteString.contains("template=bug.yml"), true)

        environment.otherHandler?()
        XCTAssertEqual(platform.openedURLs.last?.absoluteString.contains("/issues/new/choose"), true)
    }

    func testSharedFoldersUseInjectedPlatformURLs() {
        let platform = MockPlatform()
        let environment = MockEnvironment()
        let useCase = WorkspaceSupportUseCase(platform: platform, environment: environment)

        useCase.openSharedDocuments()
        useCase.openSharedArchives()
        useCase.openSharedCertificates()

        XCTAssertEqual(platform.openedURLs, [
            URL(string: "shareddocuments://documents")!,
            URL(string: "shareddocuments://archives")!,
            URL(string: "shareddocuments://certificates")!
        ])
    }
}
