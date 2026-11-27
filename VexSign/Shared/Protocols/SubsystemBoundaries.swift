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
    /// Release an owned temporary package only after its consumer has finished reading it.
    func releaseValidatedPackage(_ url: URL)
    func downloadValidatedFirmware(from url: URL, to destination: URL) async throws -> URL
    func fetchFirmwareDevices() async throws -> [FirmwareDeviceRecord]
    func fetchFirmwareBuilds(deviceIdentifier: String) async throws -> [FirmwareBuildRecord]
    func currentHardwareModelIdentifier() -> String?
}

extension SecureTransferProviding {
    // Providers without owned temporary storage need no cleanup.
    func releaseValidatedPackage(_ url: URL) {}
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
    func exportDiagnosticArchiveURL() async -> URL?
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
    /// Consent for an operation that has already staged sensitive files. Unlike the
    /// ordinary yes/no alert this also reports the decline, so the caller can remove
    /// the staged private key even when the user never taps confirm.
    func presentImportConsentAlert(
        title: String,
        message: String,
        confirmTitle: String,
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void
    )
    func presentErrorWithCopy(title: String, message: String)
    func triggerHapticFeedback(success: Bool)
}

@MainActor
extension PlatformSystemAdapting {
    /// Compatibility default for test doubles and secondary adapters. The iOS
    /// adapter overrides this so a declined consent can be reported; callers
    /// must never rely on the default to clean up sensitive staged files.
    func presentImportConsentAlert(
        title: String,
        message: String,
        confirmTitle: String,
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        presentYesNoAlert(title: title, message: message, confirmTitle: confirmTitle, onConfirm: onConfirm)
        _ = onCancel
    }
}
