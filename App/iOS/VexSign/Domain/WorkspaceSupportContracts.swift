import Foundation

/// Non-secret facts used to build a GitHub issue template.
///
/// This value deliberately contains no account identifiers, certificate bytes,
/// pairing records, UDIDs, private keys or authorization tokens. Platform code
/// produces it; the Application layer only formats it.
struct WorkspaceSupportSnapshot: Equatable, Sendable {
    let deviceModel: String
    let systemVersion: String
    let appVersion: String
    let routingPreference: String
    let installationDetails: [String]

    init(
        deviceModel: String,
        systemVersion: String,
        appVersion: String,
        routingPreference: String,
        installationDetails: [String]
    ) {
        self.deviceModel = deviceModel
        self.systemVersion = systemVersion
        self.appVersion = appVersion
        self.routingPreference = routingPreference
        self.installationDetails = installationDetails
    }
}

/// Platform boundary for support actions and environment facts.
///
/// Keeping UIKit, `UIDevice`, `UserDefaults`, `SigningModeManager` and shared
/// folder discovery behind this port lets the Application layer remain free of
/// presentation frameworks and uncontrolled globals. The composition root
/// injects the concrete adapter; tests inject a value-producing fake.
@MainActor
protocol WorkspaceSupportEnvironmentProviding: AnyObject {
    func supportSnapshot() -> WorkspaceSupportSnapshot
    func sharedDocumentsURL() -> URL?
    func sharedArchivesURL() -> URL?
    func sharedCertificatesURL() -> URL?
    func presentFeedbackOptions(
        title: String,
        message: String?,
        bugTitle: String,
        otherTitle: String,
        onBugReport: @escaping () -> Void,
        onOther: @escaping () -> Void
    )
}
