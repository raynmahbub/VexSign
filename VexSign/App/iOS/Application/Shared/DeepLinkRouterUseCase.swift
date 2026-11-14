import Foundation

/// Coordinates incoming `vexsign://`, `feather://`, `.ipa`/`.tipa`, and tweak URLs
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
        addTweakFile: @escaping (String, URL) -> Bool
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
            handleSharedTweak(fileURL)

        case .unsupported:
            diagnostics.info("Ignored unsupported incoming URL.")
        }
    }

    private func handleCertificateImport(p12Base64: String, provisionBase64: String, password: String) {
        guard
            let p12URL = decodeBase64File(p12Base64, ".p12"),
            let provisionURL = decodeBase64File(provisionBase64, ".mobileprovision"),
            validateCertificatePassword(p12URL, password, provisionURL)
        else {
            platform.triggerHapticFeedback(success: false)
            platform.presentErrorWithCopy(
                title: NSLocalizedString("Import Failed", comment: ""),
                message: NSLocalizedString("Failed to import certificate. Please check that the certificate and password are valid.", comment: "")
            )
            return
        }

        importCertificateFiles(p12URL, provisionURL, password) { [weak self] error in
            guard let self else { return }
            if let error {
                self.platform.presentErrorWithCopy(title: NSLocalizedString("Error", comment: ""), message: error.localizedDescription)
            } else {
                self.platform.triggerHapticFeedback(success: true)
            }
        }
    }

    private func handleSharedPackage(_ url: URL) {
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
