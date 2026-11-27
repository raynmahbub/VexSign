import Foundation

/// Coordinates incoming `vexsign://`, `.ipa`/`.tipa`, backup, and tweak URLs
/// with centralized security policy validation instead of burying routing logic in `VexSignApp`.
@MainActor
final class DeepLinkRouterUseCase {
    private let securityPolicy: SecurityPolicyValidating
    private let platform: PlatformSystemAdapting
    private let incomingFiles: IncomingFilesProviding
    private let diagnostics: RoutingDiagnosticsProviding
    private let decodeBase64File: (String, String) -> URL?
    private let validateCertificatePassword: (URL, String, URL) -> Bool
    private let importCertificateFiles: (URL, URL, String, @escaping (Error?) -> Void) -> Void
    private let exportCertificateTemplate: (String) -> Void
    private let addTweakRepository: (URL) async throws -> Int
    private let openRepositoryApp: (String, String, String?) -> Void
    private let navigateWorkspace: (WorkspaceDestination) -> Void
    private let launchInstalledApp: (String) -> Void
    private let addSource: (String) -> Void
    private let startPackageDownload: (URL) -> Void
    private let acquireWorkLease: () throws -> AnyObject
    private let importStagedPackage: (URL, @escaping (Error?) -> Void) -> Void
    private let extractTweakArchive: (URL) async throws -> (workDir: URL, candidateURLs: [URL])
    private let addTweakFile: (String, URL) -> Bool
    /// Hands a staged `.vexbackup` to the Backups screen. The screen owns the
    /// password prompt, decrypt, preview and restore; this router must not
    /// decrypt, restore or hold the file open itself.
    private let stageBackupFile: (URL) -> Void

    init(
        securityPolicy: SecurityPolicyValidating,
        platform: PlatformSystemAdapting,
        incomingFiles: IncomingFilesProviding,
        diagnostics: RoutingDiagnosticsProviding,
        decodeBase64File: @escaping (String, String) -> URL?,
        validateCertificatePassword: @escaping (URL, String, URL) -> Bool,
        importCertificateFiles: @escaping (URL, URL, String, @escaping (Error?) -> Void) -> Void,
        exportCertificateTemplate: @escaping (String) -> Void,
        addTweakRepository: @escaping (URL) async throws -> Int,
        openRepositoryApp: @escaping (String, String, String?) -> Void,
        navigateWorkspace: @escaping (WorkspaceDestination) -> Void,
        launchInstalledApp: @escaping (String) -> Void = { _ in },
        addSource: @escaping (String) -> Void,
        startPackageDownload: @escaping (URL) -> Void,
        acquireWorkLease: @escaping () throws -> AnyObject,
        importStagedPackage: @escaping (URL, @escaping (Error?) -> Void) -> Void,
        extractTweakArchive: @escaping (URL) async throws -> (workDir: URL, candidateURLs: [URL]),
        addTweakFile: @escaping (String, URL) -> Bool,
        stageBackupFile: @escaping (URL) -> Void = { _ in }
    ) {
        self.securityPolicy = securityPolicy
        self.platform = platform
        self.incomingFiles = incomingFiles
        self.diagnostics = diagnostics
        self.decodeBase64File = decodeBase64File
        self.validateCertificatePassword = validateCertificatePassword
        self.importCertificateFiles = importCertificateFiles
        self.exportCertificateTemplate = exportCertificateTemplate
        self.addTweakRepository = addTweakRepository
        self.openRepositoryApp = openRepositoryApp
        self.navigateWorkspace = navigateWorkspace
        self.launchInstalledApp = launchInstalledApp
        self.addSource = addSource
        self.startPackageDownload = startPackageDownload
        self.acquireWorkLease = acquireWorkLease
        self.importStagedPackage = importStagedPackage
        self.extractTweakArchive = extractTweakArchive
        self.addTweakFile = addTweakFile
        self.stageBackupFile = stageBackupFile
    }

    func handle(_ url: URL) {
        let command = DeepLinkCommand.parse(url)
        switch command {
        case .importCertificate(let p12Base64, let provisionBase64, let password):
            handleCertificateImport(p12Base64: p12Base64, provisionBase64: provisionBase64, password: password)

        case .invalidCertificateImport:
            diagnostics.warning("Rejected malformed import-certificate URL.", security: false)

        case .exportCertificate(let template):
            guard securityPolicy.isAllowedCertificateCallbackTemplate(template) else {
                diagnostics.warning("Blocked unsafe certificate export callback template.", security: true)
                return
            }
            exportCertificateTemplate(template)

        case .addTweakRepository(let repositoryURL):
            Task { @MainActor in
                do {
                    try securityPolicy.validateRepositoryURL(repositoryURL)
                    let count = try await addTweakRepository(repositoryURL)
                    platform.notifySuccess(
                        String(format: NSLocalizedString("Imported %lld tweaks", comment: ""), arguments: [count]),
                        systemImage: "wrench.and.screwdriver.fill"
                    )
                } catch {
                    platform.notifyError(diagnostics.userMessage(for: error), sticky: true)
                }
            }

        case .openRepositoryApp(let appID, let appName, let sourceIdentifier):
            openRepositoryApp(appID, appName ?? NSLocalizedString("App", comment: ""), sourceIdentifier)

        case .openWorkspace(let destination):
            navigateWorkspace(destination)

        case .launchApp(let bundleIdentifier):
            launchInstalledApp(bundleIdentifier)

        case .addSource(let sourceString):
            addSource(sourceString)

        case .downloadAndInstall(let downloadURL, let notifyDirectStarted):
            do {
                try securityPolicy.validatePackageDownloadURL(downloadURL)
                startPackageDownload(downloadURL)
                if notifyDirectStarted {
                    platform.notifyInfo(NSLocalizedString("Direct download started", comment: ""), systemImage: "arrow.down.app")
                }
            } catch {
                diagnostics.report(error)
                platform.notifyError(diagnostics.userMessage(for: error), sticky: true)
            }

        case .importPackageFile(let fileURL):
            handleSharedPackage(fileURL)

        case .importTweakFile(let fileURL):
            // The extension parser cannot tell an app someone zipped from a tweak
            // bundle: both are `.zip`. Reading the entry names here keeps the
            // parser pure and still routes the app to the library instead of
            // reporting "no tweaks found" for a file that was never a tweak.
            if Self.isApplicationArchive(fileURL) {
                handleSharedPackage(fileURL)
            } else {
                handleSharedTweak(fileURL)
            }

        case .openBackupFile(let fileURL):
            handleSharedBackup(fileURL)

        case .unsupported:
            diagnostics.info("Ignored unsupported incoming URL.")
        }
    }

    private func handleCertificateImport(p12Base64: String, provisionBase64: String, password: String) {
        guard
            let p12URL = decodeBase64File(p12Base64, ".p12"),
            let provisionURL = decodeBase64File(provisionBase64, ".mobileprovision")
        else {
            platform.triggerHapticFeedback(success: false)
            platform.presentErrorWithCopy(
                title: NSLocalizedString("Import Failed", comment: ""),
                message: NSLocalizedString("Failed to import certificate. Please check that the certificate and password are valid.", comment: "")
            )
            return
        }

        // Validate before prompting, so a malformed or substituted link cannot raise a dialog
        // that looks like a legitimate install request.
        guard validateCertificatePassword(p12URL, password, provisionURL) else {
            discardStagedCertificateFiles([p12URL, provisionURL])
            platform.triggerHapticFeedback(success: false)
            platform.presentErrorWithCopy(
                title: NSLocalizedString("Import Failed", comment: ""),
                message: NSLocalizedString("Failed to import certificate. Please check that the certificate and password are valid.", comment: "")
            )
            return
        }

        // A custom-scheme link is an untrusted sender, and an imported certificate becomes a
        // signing identity that can be used on later installs. Staging the files is safe;
        // installing the identity is not, so the user decides — the same reasoning that stages a
        // handed-over backup in `handleSharedBackup` instead of restoring it.
        platform.presentImportConsentAlert(
            title: NSLocalizedString("Import Certificate From Link?", comment: ""),
            message: NSLocalizedString("This link installs a signing certificate and its password. Only continue if you requested it from someone you trust. The certificate is not marked as default; you choose it before it signs anything.", comment: ""),
            confirmTitle: NSLocalizedString("Import", comment: ""),
            onConfirm: { [weak self] in
                guard let self else { return }
                self.importCertificateFiles(p12URL, provisionURL, password) { [weak self] error in
                    guard let self else { return }
                    self.discardStagedCertificateFiles([p12URL, provisionURL])
                    if let error {
                        self.platform.presentErrorWithCopy(title: NSLocalizedString("Error", comment: ""), message: error.localizedDescription)
                    } else {
                        self.platform.triggerHapticFeedback(success: true)
                    }
                }
            },
            onCancel: { [weak self] in
                guard let self else { return }
                // Declining an untrusted link is still a decision. The staged
                // p12 contains a private key; it must not wait for the next
                // stale-temporary sweep to disappear.
                self.discardStagedCertificateFiles([p12URL, provisionURL])
            }
        )
    }

    /// The staged `.p12`/`.mobileprovision` files are plaintext copies written by
    /// `decodeBase64File`; remove them once the outcome is known (or the pair is rejected) so a
    /// private key does not linger in the temporary directory of an app that never used it.
    /// The consent alert reports both actions, so a decline removes the staged files
    /// here as well. A platform adapter that cannot present the alert fails closed
    /// by reporting cancellation.
    private func discardStagedCertificateFiles(_ urls: [URL]) {
        for url in urls {
            incomingFiles.discardTemporaryFile(url)
        }
    }

    /// Whether a handed-over archive is an app package, whichever suffix it has.
    ///
    /// A `.zip` is byte-identical to an IPA when it holds `Payload/<name>.app`,
    /// so the content decides. An `.ipa` whose bytes are not a ZIP is left to
    /// `PackageImportService`, which refuses it with the same sentence the
    /// picker path uses.
    private static func isApplicationArchive(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() != "ipa",
              url.pathExtension.lowercased() != "tipa" else { return true }
        return withIncomingAccess(url) { readable in
            guard PackageArchiveType.accepted(at: readable) else { return false }
            return PackageContentClassifier.classify(at: readable) == .application
        }
    }

    /// Reads the incoming file with the access it needs.
    ///
    /// A file opened from Files, AirDrop or another app arrives as a
    /// security-scoped URL: reading its bytes without starting the scope fails on
    /// a device, even though the file is perfectly good. The coordinated copy
    /// takes the scope for itself, but these classification reads happen *before*
    /// it, so the URL was refused as unreadable on hardware while the simulator —
    /// where the URL points inside the sandbox — looked fine.
    ///
    /// `startAccessingSecurityScopedResource` answers `false` for a URL that was
    /// never scoped, so the replay is safe for an in-sandbox file too.
    private static func withIncomingAccess<T>(_ url: URL, _ body: (URL) -> T) -> T {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return body(url)
    }

    private func handleSharedPackage(_ url: URL) {
        // Refuse a container the importer cannot unpack before copying it into
        // the workspace: a handed-over `.tar.gz` is otherwise staged in full and
        // only then rejected by the extractor. The read is scoped, or a shared
        // IPA would be refused as unreadable on a device.
        let rejection = Self.withIncomingAccess(url) { PackageArchiveType.rejectionReason(at: $0) }
        if let reason = rejection {
            platform.presentErrorWithCopy(title: NSLocalizedString("Import Failed", comment: ""), message: reason)
            return
        }
        let workLease: AnyObject
        do {
            workLease = try acquireWorkLease()
        } catch {
            platform.notifyError(error.localizedDescription, sticky: false)
            return
        }

        let tempDir = incomingFiles.temporaryDirectory(label: "VexSignShared")
        let destinationURL = tempDir.appendingPathComponent(url.lastPathComponent)

        switch incomingFiles.copyCoordinatedFile(from: url, to: destinationURL, tempDirectory: tempDir) {
        case .failure(let reason):
            platform.presentErrorWithCopy(title: NSLocalizedString("Import Failed", comment: ""), message: reason.localizedDescription)
            return
        case .success:
            break
        }

        importStagedPackage(destinationURL) { [weak self] error in
            defer { withExtendedLifetime(workLease) {} }
            guard let self else { return }
            if error is CancellationError { return }
            if let error {
                self.platform.presentErrorWithCopy(title: NSLocalizedString("Import Failed", comment: ""), message: error.localizedDescription)
            } else {
                self.platform.notifySuccess(NSLocalizedString("Imported successfully", comment: ""), systemImage: "square.and.arrow.down.fill")
            }
        }
    }

    /// Stage a handed-over backup into the app's own temporary directory, then let
    /// the Backups screen take it. Copying here (rather than in the screen) keeps the
    /// security-scoped access next to the picker result that owns it; staging keeps
    /// the restore a deliberate, reviewed action instead of an automatic one.
    private func handleSharedBackup(_ url: URL) {
        let tempDir = incomingFiles.temporaryDirectory(label: "VexSignSharedBackup")
        let destinationURL = tempDir.appendingPathComponent(url.lastPathComponent)

        switch incomingFiles.copyCoordinatedFile(from: url, to: destinationURL, tempDirectory: tempDir) {
        case .failure(let reason):
            platform.presentErrorWithCopy(title: NSLocalizedString("Restore Failed", comment: ""), message: reason.localizedDescription)
        case .success:
            stageBackupFile(destinationURL)
            platform.notifyInfo(
                NSLocalizedString("Backup ready to restore", comment: ""),
                systemImage: "externaldrive.badge.checkmark"
            )
        }
    }

    private func handleSharedTweak(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        guard securityPolicy.isAllowedTweakExtension(ext) else { return }

        let tempDir = incomingFiles.temporaryDirectory(label: "VexSignSharedTweak")
        let destinationURL = tempDir.appendingPathComponent(url.lastPathComponent)

        guard case .success = incomingFiles.copyCoordinatedFile(from: url, to: destinationURL, tempDirectory: tempDir) else {
            platform.notifyError(NSLocalizedString("Import Failed", comment: ""), sticky: false)
            return
        }

        if ext == "zip" {
            Task { @MainActor in
                do {
                    let result = try await extractTweakArchive(destinationURL)
                    let injectables = result.candidateURLs.filter { !$0.path.contains(".app/") }
                    var added = 0
                    for candidateURL in injectables {
                        let name = candidateURL.deletingPathExtension().lastPathComponent
                        if addTweakFile(name, candidateURL) {
                            added += 1
                        }
                    }
                    incomingFiles.removeTemporaryDirectory(result.workDir)
                    incomingFiles.removeTemporaryDirectory(tempDir)
                    if added > 0 {
                        platform.notifySuccess(
                            String(format: NSLocalizedString("Added %lld tweaks", comment: ""), arguments: [added]),
                            systemImage: "wrench.and.screwdriver.fill"
                        )
                    } else {
                        platform.notifyError(NSLocalizedString("No tweaks found in the archive", comment: ""), sticky: false)
                    }
                } catch {
                    incomingFiles.removeTemporaryDirectory(tempDir)
                    platform.notifyError(error.localizedDescription, sticky: false)
                }
            }
        } else {
            let name = destinationURL.deletingPathExtension().lastPathComponent
            if addTweakFile(name, destinationURL) {
                platform.notifySuccess(NSLocalizedString("Added to Tweak Manager", comment: ""), systemImage: "wrench.and.screwdriver.fill")
            } else {
                platform.notifyError(NSLocalizedString("Couldn't import tweak", comment: ""), sticky: true)
            }
            incomingFiles.removeTemporaryDirectory(tempDir)
        }
    }

}
