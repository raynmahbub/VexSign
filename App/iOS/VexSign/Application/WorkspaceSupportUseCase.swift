import Foundation
import NimbleExtensions

/// Builds sanitized diagnostic feedback URLs and opens sandbox shared folders outside `SettingsView`.
///
/// The use case owns support *policy*: which URLs are opened, what a bug report
/// contains, and which non-secret facts are included. Platform facts and UIKit
/// presentation are supplied by explicit ports, so this Application-layer type
/// no longer imports UIKit or reads device/user-default singletons directly.
@MainActor
final class WorkspaceSupportUseCase {
    private let platform: PlatformSystemAdapting
    private let environment: WorkspaceSupportEnvironmentProviding
    private let repositoryURL = "https://github.com/raynmahbub/VexSign"

    init(
        platform: PlatformSystemAdapting,
        environment: WorkspaceSupportEnvironmentProviding
    ) {
        self.platform = platform
        self.environment = environment
    }

    func openRepository() {
        guard let url = URL(string: repositoryURL) else { return }
        platform.openExternalURL(url)
    }

    func presentFeedbackSheet() {
        environment.presentFeedbackOptions(
            title: .localized("Submit Feedback"),
            message: nil,
            bugTitle: .localized("Bug Report"),
            otherTitle: .localized("Other"),
            onBugReport: { [weak self] in
                guard let self, let url = URL(string: self.makeGitHubIssueURL()) else { return }
                self.platform.openExternalURL(url)
            },
            onOther: { [weak self] in
                guard let self, let url = URL(string: "\(self.repositoryURL)/issues/new/choose") else { return }
                self.platform.openExternalURL(url)
            }
        )
    }

    func openSharedDocuments() {
        if let url = environment.sharedDocumentsURL() {
            platform.openExternalURL(url)
        }
    }

    func openSharedArchives() {
        if let url = environment.sharedArchivesURL() {
            platform.openExternalURL(url)
        }
    }

    func openSharedCertificates() {
        if let url = environment.sharedCertificatesURL() {
            platform.openExternalURL(url)
        }
    }

    func makeGitHubIssueURL() -> String {
        let snapshot = environment.supportSnapshot()
        var configurationSection = "### App Configuration:\n"
        configurationSection += "- App routing preference: `\(snapshot.routingPreference)`\n"
        if !snapshot.installationDetails.isEmpty {
            configurationSection += snapshot.installationDetails.joined(separator: "\n")
            configurationSection += "\n"
        }

        let body = """
        ### Device Information
        - Device: `\(snapshot.deviceModel)`
        - iOS Version: `\(snapshot.systemVersion)`
        - App Version: `\(snapshot.appVersion)`

        \(configurationSection)
        ### Issue Description
        <!-- Describe your issue here -->

        ### Steps to Reproduce
        1.
        2.
        3.

        ### Expected Behavior

        ### Actual Behavior
        """
        let encodedTitle = "[Bug] replace this with a descriptive title ".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let encodedBody = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return "\(repositoryURL)/issues/new?template=bug.yml&title=\(encodedTitle)&text=\(encodedBody)"
    }
}
