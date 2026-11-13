import Foundation
import NimbleExtensions

/// Coordinates direct URL package download, security validation, import, and direct/containerized installation.
@MainActor
final class DirectPackageInstallUseCase {
    private let securityPolicy: SecurityPolicyValidating
    private let transferService: SecureTransferProviding
    private let maximumPackageBytes: Int64
    private let isContainerizedPipeline: () throws -> Bool
    private let isContainerizedAppPipeline: (AppInfoPresentable) throws -> Bool
    private let enqueueDownload: (URL, String) -> Void
    private let acquireTemporaryWork: () throws -> AnyObject
    private let importPackageFile: (URL) async throws -> AppInfoPresentable
    private let performDirectInstall: (AppInfoPresentable, Bool) throws -> Void

    private var pendingImportedApp: AppInfoPresentable?

    init(
        securityPolicy: SecurityPolicyValidating,
        transferService: SecureTransferProviding,
        maximumPackageBytes: Int64 = DownloadIntegrity.maximumPackageBytes,
        isContainerizedPipeline: @escaping () throws -> Bool,
        isContainerizedAppPipeline: @escaping (AppInfoPresentable) throws -> Bool,
        enqueueDownload: @escaping (URL, String) -> Void,
        acquireTemporaryWork: @escaping () throws -> AnyObject,
        importPackageFile: @escaping (URL) async throws -> AppInfoPresentable,
        performDirectInstall: @escaping (AppInfoPresentable, Bool) throws -> Void
    ) {
        self.securityPolicy = securityPolicy
        self.transferService = transferService
        self.maximumPackageBytes = maximumPackageBytes
        self.isContainerizedPipeline = isContainerizedPipeline
        self.isContainerizedAppPipeline = isContainerizedAppPipeline
        self.enqueueDownload = enqueueDownload
        self.acquireTemporaryWork = acquireTemporaryWork
        self.importPackageFile = importPackageFile
        self.performDirectInstall = performDirectInstall
    }

    func execute(
        urlString: String,
        mode: DirectInstallMode,
        onStatus: (String) -> Void
    ) async throws -> DirectInstallResult {
        pendingImportedApp = nil

        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let targetURL = URL(string: trimmed),
              targetURL.scheme != nil else {
            throw ArchitectureDomainError.invalidURL(trimmed)
        }

        try securityPolicy.validatePackageDownloadURL(targetURL)

        let preparesGuestDefault = try isContainerizedPipeline()
        if mode == .signAndInstall && !preparesGuestDefault {
            let appName = targetURL.deletingPathExtension().lastPathComponent
            enqueueDownload(targetURL, appName)
            return .queuedForDownloadAndSign
        }

        let workLease = try acquireTemporaryWork()
        defer { withExtendedLifetime(workLease) {} }

        onStatus(.localized("Downloading…"))
        let downloadedURL = try await transferService.downloadValidatedPackage(
            from: targetURL,
            workLabel: "DirectInstall",
            maximumBytes: maximumPackageBytes
        )

        onStatus(.localized("Importing…"))
        let imported = try await importPackageFile(downloadedURL)

        let preparesGuestForApp: Bool
        do {
            preparesGuestForApp = try isContainerizedAppPipeline(imported)
        } catch {
            SubsystemDiagnosticsLog.warn(
                "Could not determine containerized status prior to direct install: \(error.localizedDescription)",
                subsystem: .install
            )
            preparesGuestForApp = false
        }
        onStatus(preparesGuestForApp ? .localized("Preparing guest import…") : .localized("Verifying signature…"))

        do {
            try performDirectInstall(imported, false)
            return preparesGuestForApp ? .installedAsContainerGuest : .installedDirectly
        } catch DirectInstaller.DirectInstallError.verificationFailed(let issues) {
            pendingImportedApp = imported
            return .needsIssueConfirmation(issues)
        }
    }

    func confirmPendingInstall() throws -> DirectInstallResult {
        guard let app = pendingImportedApp else {
            throw ArchitectureDomainError.importFailed("No pending package awaiting confirmation.")
        }
        pendingImportedApp = nil
        try performDirectInstall(app, true)
        return .installedDirectly
    }
}
