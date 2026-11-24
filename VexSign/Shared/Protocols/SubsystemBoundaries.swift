import Foundation

// MARK: - Security & Transfer Boundaries

protocol SecurityPolicyValidating: Sendable {
    func validatePackageDownloadURL(_ url: URL) throws
    func validateFirmwareDownloadURL(_ url: URL) throws
    func validateRepositoryURL(_ url: URL) throws
    func isAllowedCertificateCallbackTemplate(_ template: String) -> Bool
    func isAllowedPackageExtension(_ ext: String) -> Bool
    func isAllowedTweakExtension(_ ext: String) -> Bool
}

/// The one list of schemes a certificate callback may never use.
///
/// Two layers enforce this and they must not drift apart. The deep-link router checks the
/// *template* before anything is substituted, so an obviously unsafe destination is refused
/// early; `CertificateManagementService` re-checks the *resolved URL*, after the certificate and
/// its password are already interpolated and could in principle have rewritten the scheme. Those
/// were two literal copies of the same six schemes, so adding one to a copy left the other layer
/// disagreeing about what a safe callback is.
///
/// Note this is a deny-list by design: a certificate export is meant to hand an identity to
/// another app over that app's own custom scheme, so the schemes cannot be enumerated. What it
/// rules out is the ones that leave the device or run content.
enum CertificateCallbackPolicy {
    static let disallowedSchemes: Set<String> = [
        "http", "https", "file", "javascript", "data", "about"
    ]
}

protocol SecureTransferProviding {
    func downloadValidatedPackage(from url: URL, workLabel: String, maximumBytes: Int64) async throws -> URL
    func downloadValidatedFirmware(from url: URL, to destination: URL) async throws -> URL
    func fetchFirmwareDevices() async throws -> [FirmwareDeviceRecord]
    func fetchFirmwareBuilds(deviceIdentifier: String) async throws -> [FirmwareBuildRecord]
    func currentHardwareModelIdentifier() -> String?
}

// MARK: - Workspace & Storage Boundaries

@MainActor
protocol WorkspaceResetting: AnyObject {
    func currentSummary() -> WorkspaceCountsSummary
    func perform(_ scope: WorkspaceResetScope)
}

@MainActor
protocol DownloadedFilesManaging: AnyObject {
    func listStagedPackages() -> [DownloadedFileItem]
    func importFiles(_ urls: [URL], intoStaging: Bool) -> Int
    func importToLibrary(from stagedURL: URL) -> Bool
    func stagingDirectoryURL() -> URL
    func sharedDocumentsURL(for url: URL) -> URL?
}

// MARK: - Diagnostics & Privacy Boundaries

@MainActor
protocol DiagnosticsProviding: AnyObject {
    func currentSnapshot() -> DiagnosticOverviewSnapshot
    func exportDiagnosticArchiveURL() -> URL?
}

@MainActor
protocol AppPrivacyManaging: AnyObject {
    var strictHidingEnabled: Bool { get set }
    var isRevealingHiddenApps: Bool { get }
    var biometryDisplayName: String? { get }
    func allLibraryApps() -> [AppPrivacyItem]
    func isAppLocked(_ uuid: String) -> Bool
    func isAppHidden(_ uuid: String) -> Bool
    func toggleAppLock(_ uuid: String)
    func toggleHideApp(_ uuid: String)
    func authenticateToRevealHidden(completion: @escaping (Bool) -> Void)
}

@MainActor
protocol StoreRecoveryReporting: AnyObject {
    /// Non-nil only in the session where an unreadable store was quarantined.
    var pendingLibraryRecovery: LibraryRecoveryNotice? { get }
    func acknowledgeLibraryRecovery()
}

@MainActor
protocol CertificateCatalogProviding: AnyObject {
    func certificateOptions() -> [CertificateOptionItem]
    func signedAppsCount() -> Int
}

// MARK: - Platform System Hooks

@MainActor
protocol PlatformSystemAdapting: AnyObject {
    func openExternalURL(_ url: URL)
    func pasteboardString() -> String?
    func dismissKeyboard()
    func restartOrSuspendApp()
    func shareItems(_ items: [Any])
    func notifySuccess(_ message: String, systemImage: String)
    func notifyInfo(_ message: String, systemImage: String)
    func notifyError(_ message: String, sticky: Bool)
    func presentDestructiveConfirmation(title: String, message: String, onConfirm: @escaping () -> Void)
    func presentYesNoAlert(title: String, message: String, confirmTitle: String, onConfirm: @escaping () -> Void)
    func presentErrorWithCopy(title: String, message: String)
    func triggerHapticFeedback(success: Bool)
}
