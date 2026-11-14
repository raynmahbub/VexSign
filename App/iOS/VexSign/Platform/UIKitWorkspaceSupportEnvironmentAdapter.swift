import Foundation
import UIKit
import NimbleExtensions

/// UIKit/platform implementation of the support-environment port.
///
/// This is the only place that reads `UIDevice`, `UserDefaults`, the shared
/// signing-mode manager and shared-folder paths for issue reports. It emits a
/// small, non-secret value snapshot; no private key, pairing record, UDID,
/// certificate payload or account token crosses into the Application layer.
@MainActor
final class UIKitWorkspaceSupportEnvironmentAdapter: WorkspaceSupportEnvironmentProviding {
    func supportSnapshot() -> WorkspaceSupportSnapshot {
        let modeManager = SigningModeManager.shared
        var installationDetails: [String] = []

        do {
            switch try modeManager.pipeline() {
            case .directPaid(.server):
                let serverMethod = UserDefaults.standard.integer(forKey: "VexSign.serverMethod")
                let ipFix = UserDefaults.standard.bool(forKey: "VexSign.ipFix")
                let serverType = (serverMethod == 0) ? "Fully Local" : "Semi Local"
                installationDetails.append("- Install method: `Server`")
                installationDetails.append("  - Server type: `\(serverType)`")
                installationDetails.append("  - IP Fix: `\(ipFix)`")
            case .directPaid(.idevice):
                let pairingExists = PairingBridge.hasPairingFile
                installationDetails.append("- Install method: `idevice`")
                installationDetails.append("  - Pairing file: `\(pairingExists ? "Present" : "Not Present")`")
            case .containerized:
                installationDetails.append("- Install method: `Embedded guest import`")
            case .directPaid:
                installationDetails.append("- Install method: `Unsupported direct route`")
            }
        } catch {
            installationDetails.append("- Install method: `Unresolved`")
        }

        return WorkspaceSupportSnapshot(
            deviceModel: MobileGestalt.physicalHardwareName ?? "Unknown",
            systemVersion: UIDevice.current.systemVersion,
            appVersion: Bundle.main.version,
            routingPreference: modeManager.preference.rawValue,
            installationDetails: installationDetails
        )
    }

    func sharedDocumentsURL() -> URL? {
        URL.documentsDirectory.toSharedDocumentsURL()
    }

    func sharedArchivesURL() -> URL? {
        FileManager.default.archives.toSharedDocumentsURL()
    }

    func sharedCertificatesURL() -> URL? {
        FileManager.default.certificates.toSharedDocumentsURL()
    }

    func presentFeedbackOptions(
        title: String,
        message: String?,
        bugTitle: String,
        otherTitle: String,
        onBugReport: @escaping () -> Void,
        onOther: @escaping () -> Void
    ) {
        let bugAction = UIAlertAction(title: bugTitle, style: .default) { _ in
            onBugReport()
        }
        let chooseAction = UIAlertAction(title: otherTitle, style: .default) { _ in
            onOther()
        }
        UIAlertController.showAlertWithCancel(
            title: title,
            message: message,
            actions: [bugAction, chooseAction]
        )
    }
}
