import Foundation
import NimbleExtensions

/// Coordinates incoming `vexsign://`, `feather://`, `.ipa`/`.tipa`, and tweak URLs
/// with centralized security policy validation instead of burying routing logic in `VexSignApp`.
@MainActor
final class DeepLinkRouterUseCase {
    private let securityPolicy: SecurityPolicyValidating
    private let platform: PlatformSystemAdapting
    private let decodeBase64File: (String, String) -> URL?
    private let validateCertificatePassword: (URL, String, URL) -> Bool
    private let importCertificateFiles: (URL, URL, String, @escaping (Error?) -> Void) -> Void
    private let exportCertificateTemplate: (String) -> Void
    private let addTweakRepository: (URL) async throws -> Int
    private let openRepositoryApp: (String, String, String?) -> Void
    private let navigateWorkspace: (WorkspaceDestination) -> Void
    private let addSource: (String) -> Void
    private let startPackageDownload: (URL) -> Void
    private let acquireWorkLease: () throws -> AnyObject
    private let importStagedPackage: (URL, @escaping (Error?) -> Void) -> Void
    private let extractTweakArchive: (URL) async throws -> (workDir: URL, candidateURLs: [URL])
    private let addTweakFile: (String, URL) -> Bool

    init(
        securityPolicy: SecurityPolicyValidating,
        platform: PlatformSystemAdapting,
        decodeBase64File: @escaping (String, String) -> URL?,
        validateCertificatePassword: @escaping (URL, String, URL) -> Bool,
        importCertificateFiles: @escaping (URL, URL, String, @escaping (Error?) -> Void) -> Void,
        exportCertificateTemplate: @escaping (String) -> Void,
        addTweakRepository: @escaping (URL) async throws -> Int,
        openRepositoryApp: @escaping (String, String, String?) -> Void,
        navigateWorkspace: @escaping (WorkspaceDestination) -> Void,
        addSource: @escaping (String) -> Void,
        startPackageDownload: @escaping (URL) -> Void,
        acquireWorkLease: @escaping () throws -> AnyObject,
        importStagedPackage: @escaping (URL, @escaping (Error?) -> Void) -> Void,
        extractTweakArchive: @escaping (URL) async throws -> (workDir: URL, candidateURLs: [URL]),
        addTweakFile: @escaping (String, URL) -> Bool
    ) {
        self.securityPolicy = securityPolicy
        self.platform = platform
        self.decodeBase64File = decodeBase64File
        self.validateCertificatePassword = validateCertificatePassword
        self.importCertificateFiles = importCertificateFiles
        self.exportCertificateTemplate = exportCertificateTemplate
        self.addTweakRepository = addTweakRepository
        self.openRepositoryApp = openRepositoryApp
        self.navigateWorkspace = navigateWorkspace
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
            SubsystemDiagnosticsLog.warn("Rejected malformed import-certificate URL.", subsystem: .routing)

        case .exportCertificate(let template):
            guard securityPolicy.isAllowedCertificateCallbackTemplate(template) else {
                SubsystemDiagnosticsLog.warn("Blocked unsafe certificate export callback template.", subsystem: .security)
                return
            }
            exportCertificateTemplate(template)

        case .addTweakRepository(let repositoryURL):
            Task { @MainActor in
                do {
                    try securityPolicy.validateRepositoryURL(repositoryURL)
                    let count = try await addTweakRepository(repositoryURL)
                    platform.notifySuccess(
                        String.localized("Imported %lld tweaks", arguments: count),
                        systemImage: "wrench.and.screwdriver.fill"
                    )
                } catch {
                    platform.notifyError(ErrorBoundary.userMessage(for: error), sticky: true)
                }
            }

        case .openRepositoryApp(let appID, let appName, let sourceIdentifier):
            openRepositoryApp(appID, appName ?? .localized("App"), sourceIdentifier)

        case .openWorkspace(let destination):
            navigateWorkspace(destination)

        case .addSource(let sourceString):
            addSource(sourceString)

        case .downloadAndInstall(let downloadURL, let notifyDirectStarted):
            do {
                try securityPolicy.validatePackageDownloadURL(downloadURL)
                startPackageDownload(downloadURL)
                if notifyDirectStarted {
                    platform.notifyInfo(.localized("Direct download started"), systemImage: "arrow.down.app")
                }
            } catch {
                SubsystemDiagnosticsLog.error(error, subsystem: .security)
                platform.notifyError(ErrorBoundary.userMessage(for: error), sticky: true)
            }

        case .importPackageFile(let fileURL):
            handleSharedPackage(fileURL)

        case .importTweakFile(let fileURL):
            handleSharedTweak(fileURL)

        case .unsupported:
            SubsystemDiagnosticsLog.info("Ignored unsupported incoming URL.", subsystem: .routing)
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
                title: .localized("Import Failed"),
                message: .localized("Failed to import certificate. Please check that the certificate and password are valid.")
            )
            return
        }

        importCertificateFiles(p12URL, provisionURL, password) { [weak self] error in
            guard let self else { return }
            if let error {
                self.platform.presentErrorWithCopy(title: .localized("Error"), message: error.localizedDescription)
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

        let tempDir = FileManager.default.uniqueTemporaryDirectory("VexSignShared")
        let destinationURL = tempDir.appendingPathComponent(url.lastPathComponent)

        switch copyCoordinatedFile(from: url, to: destinationURL, tempDirectory: tempDir) {
        case .failure(let reason):
            platform.presentErrorWithCopy(title: .localized("Import Failed"), message: reason)
            return
        case .success:
            break
        }

        importStagedPackage(destinationURL) { [weak self] error in
            defer { withExtendedLifetime(workLease) {} }
            guard let self else { return }
            if error is CancellationError { return }
            if let error {
                self.platform.presentErrorWithCopy(title: .localized("Import Failed"), message: error.localizedDescription)
            } else {
                self.platform.notifySuccess(.localized("Imported successfully"), systemImage: "square.and.arrow.down.fill")
            }
        }
    }

    private func handleSharedTweak(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        guard securityPolicy.isAllowedTweakExtension(ext) else { return }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VexSignSharedTweak_\(UUID().uuidString)", isDirectory: true)
        let destinationURL = tempDir.appendingPathComponent(url.lastPathComponent)

        guard case .success = copyCoordinatedFile(from: url, to: destinationURL, tempDirectory: tempDir) else {
            platform.notifyError(.localized("Import Failed"), sticky: false)
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
                    removeDirectory(result.workDir)
                    removeDirectory(tempDir)
                    if added > 0 {
                        platform.notifySuccess(
                            String.localized("Added %lld tweaks", arguments: added),
                            systemImage: "wrench.and.screwdriver.fill"
                        )
                    } else {
                        platform.notifyError(.localized("No tweaks found in the archive"), sticky: false)
                    }
                } catch {
                    removeDirectory(tempDir)
                    platform.notifyError(error.localizedDescription, sticky: false)
                }
            }
        } else {
            let name = destinationURL.deletingPathExtension().lastPathComponent
            if addTweakFile(name, destinationURL) {
                platform.notifySuccess(.localized("Added to Tweak Manager"), systemImage: "wrench.and.screwdriver.fill")
            } else {
                platform.notifyError(.localized("Couldn't import tweak"), sticky: true)
            }
            removeDirectory(tempDir)
        }
    }

    private func copyCoordinatedFile(from url: URL, to destinationURL: URL, tempDirectory: URL) -> Result<Void, String> {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let coordinator = NSFileCoordinator()
        var coordinatorError: NSError?
        var copyError: Error?

        coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinatorError) { sourceURL in
            do {
                try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            } catch {
                copyError = error
            }
        }

        if let error = copyError {
            return .failure("Could not copy the shared file into the app.\n\nFile: \(url.lastPathComponent)\nReason: \(error.localizedDescription)")
        }
        if let error = coordinatorError {
            return .failure("Could not read the shared file. The other app may have denied access.\n\nFile: \(url.lastPathComponent)\nReason: \(error.localizedDescription)")
        }
        guard FileManager.default.fileExists(atPath: destinationURL.path) else {
            return .failure("The shared file could not be copied into the app. It may be inaccessible, or storage may be full.\n\nFile: \(url.lastPathComponent)")
        }
        return .success(())
    }

    private func removeDirectory(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            SubsystemDiagnosticsLog.warn(
                "Could not remove temporary directory \(url.lastPathComponent): \(error.localizedDescription)",
                subsystem: .storage
            )
        }
    }
}
