import Foundation
import UIKit
import NimbleExtensions

/// Builds sanitized diagnostic feedback URLs and opens sandbox shared folders outside `SettingsView`.
@MainActor
final class WorkspaceSupportUseCase {
    private let platform: PlatformSystemAdapting
    private let repositoryURL = "https://github.com/raynmahbub/VexSign"

    init(platform: PlatformSystemAdapting) {
        self.platform = platform
    }

    func openRepository() {
        guard let url = URL(string: repositoryURL) else { return }
        platform.openExternalURL(url)
    }

    func presentFeedbackSheet() {
        let bugAction = UIAlertAction(title: .localized("Bug Report"), style: .default) { [weak self] _ in
            guard let self, let url = URL(string: self.makeGitHubIssueURL()) else { return }
            self.platform.openExternalURL(url)
        }
        let chooseAction = UIAlertAction(title: .localized("Other"), style: .default) { [weak self] _ in
            guard let self, let url = URL(string: "\(self.repositoryURL)/issues/new/choose") else { return }
            self.platform.openExternalURL(url)
        }
        UIAlertController.showAlertWithCancel(
            title: .localized("Submit Feedback"),
            message: nil,
            actions: [bugAction, chooseAction]
        )
    }

    func openSharedDocuments() {
        if let url = URL.documentsDirectory.toSharedDocumentsURL() {
            platform.openExternalURL(url)
        }
    }

    func openSharedArchives() {
        if let url = FileManager.default.archives.toSharedDocumentsURL() {
            platform.openExternalURL(url)
        }
    }

    func openSharedCertificates() {
        if let url = FileManager.default.certificates.toSharedDocumentsURL() {
            platform.openExternalURL(url)
        }
    }

    func makeGitHubIssueURL() -> String {
        var configurationSection = "### App Configuration:\n"
        let modeManager = SigningModeManager.shared
        configurationSection += "- App routing preference: `\(modeManager.preference.rawValue)`\n"
        do {
            switch try modeManager.pipeline() {
            case .directPaid(.server):
                let serverMethod = UserDefaults.standard.integer(forKey: "VexSign.serverMethod")
                let ipFix = UserDefaults.standard.bool(forKey: "VexSign.ipFix")
                let serverType = (serverMethod == 0) ? "Fully Local" : "Semi Local"
                configurationSection += "- Install method: `Server`\n"
                configurationSection += "  - Server type: `\(serverType)`\n"
                configurationSection += "  - IP Fix: `\(ipFix)`\n"
            case .directPaid(.idevice):
                let pairingExists = PairingBridge.hasPairingFile
                configurationSection += "- Install method: `idevice`\n"
                configurationSection += "  - Pairing file: `\(pairingExists ? "Present" : "Not Present")`\n"
            case .containerized:
                configurationSection += "- Install method: `Embedded guest import`\n"
            case .directPaid:
                configurationSection += "- Install method: `Unsupported direct route`\n"
            }
        } catch {
            configurationSection += "- Install method: `Unresolved`\n"
        }

        let body = """
        ### Device Information
        - Device: `\(MobileGestalt.physicalHardwareName ?? "Unknown")`
        - iOS Version: `\(UIDevice.current.systemVersion)`
        - App Version: `\(Bundle.main.version)`

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
