import Foundation

/// Validates and orchestrates a direct import/installation request through Domain
/// ports. Accepted submissions must never be presented as confirmed installations.
@MainActor
final class DirectPackageInstallUseCase {
    private let securityPolicy: SecurityPolicyValidating
    private let transferService: SecureTransferProviding
    private let maximumPackageBytes: Int64
    private let installation: DirectInstallationProviding
    private var pendingPackage: ImportedPackageHandle?
    private var working = false
    private var retired = false

    init(
        securityPolicy: SecurityPolicyValidating,
        transferService: SecureTransferProviding,
        maximumPackageBytes: Int64,
        installation: DirectInstallationProviding
    ) {
        self.securityPolicy = securityPolicy
        self.transferService = transferService
        self.maximumPackageBytes = maximumPackageBytes
        self.installation = installation
    }

    /// Retires this caller's intent and process-local confirmation handle only.
    /// The caller cancels its task; an in-flight worker still owns admission and
    /// its lease until it returns. Registered artifacts and accepted queue/install
    /// handoffs belong to their existing owners and are never rolled back here.
    func cancel() {
        retired = true
        releasePendingPackage()
    }

    func execute(
        urlString: String,
        mode: DirectInstallMode,
        onStatus: (String) -> Void
    ) async throws -> DirectInstallResult {
        // A rejected/cancelled second call cannot discard the first call's
        // pending warning or clear its busy state across an actor reentrancy.
        guard !working else { throw ArchitectureDomainError.duplicateOrBusyOperation }
        try Task.checkCancellation()
        working = true
        retired = false
        defer { working = false }
        releasePendingPackage()

        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let targetURL = URL(string: trimmed), targetURL.scheme != nil else {
            throw ArchitectureDomainError.invalidURL(trimmed)
        }
        try securityPolicy.validatePackageDownloadURL(targetURL)

        let preparesGuest = try installation.currentPipelineIsContainerized()
        try checkAdmission()
        if mode == .signAndInstall && !preparesGuest {
            installation.enqueueDownload(targetURL, name: targetURL.deletingPathExtension().lastPathComponent)
            return .queuedForDownloadAndSign
        }

        let lease = try installation.acquireTemporaryWork()
        defer { withExtendedLifetime(lease) {} }
        onStatus(NSLocalizedString("Downloading…", comment: ""))
        try checkAdmission()
        let downloadedURL = try await transferService.downloadValidatedPackage(
            from: targetURL, workLabel: "DirectInstall", maximumBytes: maximumPackageBytes
        )
        // The importer owns its own copy. Keep the transfer alive until that
        // reader returns, including cooperative cancellation, then release it.
        defer { transferService.releaseValidatedPackage(downloadedURL) }
        try checkAdmission()
        onStatus(NSLocalizedString("Importing…", comment: ""))
        try checkAdmission()
        let package = try await installation.importPackage(downloadedURL)
        defer {
            if pendingPackage != package { installation.releaseImportedPackage(package) }
        }
        try checkAdmission()
        // Unknown routing is an error, not permission to silently fall back to a
        // different installation strategy.
        let isGuest = try installation.isContainerized(package)
        onStatus(isGuest ? NSLocalizedString("Preparing guest import…", comment: "") : NSLocalizedString("Verifying signature…", comment: ""))
        try checkAdmission()
        do {
            try installation.submitInstallation(package, allowingIssues: false)
            return isGuest ? .submittedForGuestImport : .submittedForInstallation
        } catch DirectInstallationRequestError.verificationFailed(let issues) {
            try checkAdmission()
            pendingPackage = package
            return .needsIssueConfirmation(issues)
        }
    }

    func confirmPendingInstall() throws -> DirectInstallResult {
        guard !working else { throw ArchitectureDomainError.duplicateOrBusyOperation }
        guard let package = pendingPackage else {
            throw ArchitectureDomainError.importFailed("No pending package awaiting confirmation.")
        }
        pendingPackage = nil
        defer { installation.releaseImportedPackage(package) }
        try checkAdmission()
        let isGuest = try installation.isContainerized(package)
        try checkAdmission()
        try installation.submitInstallation(package, allowingIssues: true)
        return isGuest ? .submittedForGuestImport : .submittedForInstallation
    }

    private func checkAdmission() throws {
        try Task.checkCancellation()
        guard !retired else { throw CancellationError() }
    }

    private func releasePendingPackage() {
        guard let package = pendingPackage else { return }
        pendingPackage = nil
        installation.releaseImportedPackage(package)
    }
}
