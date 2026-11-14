import Foundation
import Combine
import NimbleExtensions

/// Explicit Composition Root & Dependency Container for VexSign.
///
/// Created once at app startup (`AppContainer.live()`) and propagated down SwiftUI via
/// `@Environment(\.appContainer)`. Tests construct isolated instances with fakes/mocks
/// without touching global `.shared` singletons.
@MainActor
final class AppContainer: ObservableObject {
    let securityPolicy: SecurityPolicyValidating
    let transferService: SecureTransferProviding
    let platform: PlatformSystemAdapting
    let resetStore: WorkspaceResetting
    let downloadedFiles: DownloadedFilesManaging
    let diagnosticsProvider: DiagnosticsProviding
    let privacyManager: AppPrivacyManaging
    let certificateCatalog: CertificateCatalogProviding
    let workspaceSupportEnvironment: WorkspaceSupportEnvironmentProviding

    private let directInstallFactory: () -> DirectPackageInstallUseCase
    private let firmwareDownloadFactory: () -> FirmwareDownloadUseCase
    private let deepLinkRouterFactory: () -> DeepLinkRouterUseCase
    private let homePackageEnqueue: (URL, Bool) -> Void
    private let homeURLDownload: (URL) -> Bool
    private let homeRevealTab: (TabEnum) -> Void

    init(
        securityPolicy: SecurityPolicyValidating,
        transferService: SecureTransferProviding,
        platform: PlatformSystemAdapting,
        resetStore: WorkspaceResetting,
        downloadedFiles: DownloadedFilesManaging,
        diagnosticsProvider: DiagnosticsProviding,
        privacyManager: AppPrivacyManaging,
        certificateCatalog: CertificateCatalogProviding,
        workspaceSupportEnvironment: WorkspaceSupportEnvironmentProviding,
        directInstallFactory: @escaping () -> DirectPackageInstallUseCase,
        firmwareDownloadFactory: @escaping () -> FirmwareDownloadUseCase,
        deepLinkRouterFactory: @escaping () -> DeepLinkRouterUseCase,
        homePackageEnqueue: @escaping (URL, Bool) -> Void,
        homeURLDownload: @escaping (URL) -> Bool,
        homeRevealTab: @escaping (TabEnum) -> Void
    ) {
        self.securityPolicy = securityPolicy
        self.transferService = transferService
        self.platform = platform
        self.resetStore = resetStore
        self.downloadedFiles = downloadedFiles
        self.diagnosticsProvider = diagnosticsProvider
        self.privacyManager = privacyManager
        self.certificateCatalog = certificateCatalog
        self.workspaceSupportEnvironment = workspaceSupportEnvironment
        self.directInstallFactory = directInstallFactory
        self.firmwareDownloadFactory = firmwareDownloadFactory
        self.deepLinkRouterFactory = deepLinkRouterFactory
        self.homePackageEnqueue = homePackageEnqueue
        self.homeURLDownload = homeURLDownload
        self.homeRevealTab = homeRevealTab
    }

    // MARK: - Production Composition Root

    static func live() -> AppContainer {
        let security = SecurityPolicyGateway()
        let transfer = NetworkTransferAdapter(securityPolicy: security)
        let platform = UIKitPlatformAdapter()
        let resetStore = CoreDataWorkspaceResetAdapter()
        let downloadedFiles = FileSystemDownloadedFilesAdapter()
        let diagnostics = DiagnosticsRepositoryAdapter()
        let privacy = AppPrivacyAdapter()
        let certCatalog = CertificateCatalogAdapter()
        let workspaceSupport = UIKitWorkspaceSupportEnvironmentAdapter()

        return AppContainer(
            securityPolicy: security,
            transferService: transfer,
            platform: platform,
            resetStore: resetStore,
            downloadedFiles: downloadedFiles,
            diagnosticsProvider: diagnostics,
            privacyManager: privacy,
            certificateCatalog: certCatalog,
            workspaceSupportEnvironment: workspaceSupport,
            directInstallFactory: {
                DirectPackageInstallUseCase(
                    securityPolicy: security,
                    transferService: transfer,
                    maximumPackageBytes: DownloadIntegrity.maximumPackageBytes,
                    isContainerizedPipeline: {
                        try SigningModeManager.shared.pipeline() == .containerized
                    },
                    isContainerizedAppPipeline: { app in
                        try SigningModeManager.shared.pipeline(for: app) == .containerized
                    },
                    enqueueDownload: { url, appName in
                        _ = DownloadManager.shared.startDownload(from: url, appName: appName)
                    },
                    acquireTemporaryWork: {
                        try AppOperationRegistry.shared.acquireTemporaryWork()
                    },
                    importPackageFile: { url in
                        try await withCheckedThrowingContinuation { continuation in
                            PackageImportService.importPackage(url) { result in
                                continuation.resume(with: result)
                            }
                        }
                    },
                    performDirectInstall: { app, allowingIssues in
                        try DirectInstaller.shared.install(app, allowingIssues: allowingIssues)
                    }
                )
            },
            firmwareDownloadFactory: {
                FirmwareDownloadUseCase(
                    securityPolicy: security,
                    transferService: transfer,
                    firmwareDirectory: FileManager.default.firmware,
                    startKeepAlive: {
                        let keepAlive = BackgroundTaskManager(
                            taskName: "Firmware",
                            expirationTitle: .localized("Firmware download continuing"),
                            expirationBody: .localized("The download will continue when you reopen the app")
                        )
                        keepAlive.start()
                        return { keepAlive.stop() }
                    }
                )
            },
            deepLinkRouterFactory: {
                DeepLinkRouterUseCase(
                    securityPolicy: security,
                    platform: platform,
                    decodeBase64File: { base64, suffix in
                        FileManager.default.decodeAndWrite(base64: base64, pathComponent: suffix)
                    },
                    validateCertificatePassword: { p12, password, provision in
                        CertificateManagementService.validateCertificatePassword(for: p12, with: password, using: provision)
                    },
                    importCertificateFiles: { p12, provision, password, completion in
                        CertificateManagementService.importCertificateFiles(
                            p12URL: p12,
                            provisionURL: provision,
                            p12Password: password,
                            completion: completion
                        )
                    },
                    exportCertificateTemplate: { template in
                        CertificateManagementService.exportCertificateAndOpenURL(using: template)
                    },
                    addTweakRepository: { url in
                        try await TweakManager.shared.addRepository(url)
                    },
                    openRepositoryApp: { appID, appName, sourceIdentifier in
                        AppNavigationManager.shared.forceNavigateToApp(
                            appId: appID,
                            appName: appName,
                            sourceIdentifier: sourceIdentifier
                        )
                    },
                    navigateWorkspace: { destination in
                        let route: WorkspaceRoute
                        switch destination {
                        case .home: route = .home
                        case .apps: route = .apps
                        case .files: route = .files
                        case .signedApps: route = .signedApps
                        case .appStore: route = .appStore
                        case .downloads: route = .downloads
                        case .tasks: route = .tasks
                        case .logs: route = .logs
                        case .settings: route = .settings
                        }
                        TabSelectionObserver.shared.navigate(to: route)
                    },
                    launchInstalledApp: { bundleID in
                        AppLauncher.open(bundleID)
                    },
                    addSource: { sourceString in
                        RepositoryCatalogService.addSource(sourceString) { _ in }
                    },
                    startPackageDownload: { url in
                        _ = DownloadManager.shared.startDownload(from: url)
                    },
                    acquireWorkLease: {
                        try AppOperationRegistry.shared.acquireTemporaryWork()
                    },
                    importStagedPackage: { stagedURL, completion in
                        let id = "VexSignManualDownload_\(UUID().uuidString)"
                        _ = DownloadManager.shared.startArchive(from: stagedURL, id: id, completion: completion)
                    },
                    extractTweakArchive: { url in
                        let result = try await TweakExtractor.extract(fromZip: url)
                        return (result.workDir, result.candidates.map(\.url))
                    },
                    addTweakFile: { name, url in
                        TweakManager.shared.addTweak(name: name, from: url) != nil
                    }
                )
            },
            homePackageEnqueue: { stagedURL, _ in
                _ = DownloadManager.shared.startArchive(
                    from: stagedURL,
                    id: "VexSignHomeImport_\(UUID().uuidString)",
                    appName: stagedURL.deletingPathExtension().lastPathComponent,
                    reviewDuplicates: true
                ) { error in
                    if error is CancellationError { return }
                    if let error {
                        Toast.error(error.localizedDescription, duration: .long)
                    }
                }
            },
            homeURLDownload: { url in
                let manager = DownloadManager.shared
                let download = manager.startDownload(
                    from: url,
                    id: "VexSignHomeURL_\(UUID().uuidString)",
                    appName: url.deletingPathExtension().lastPathComponent
                )
                return VexHomeDownloadFeedback.isTracked(download, in: manager.downloads)
            },
            homeRevealTab: { tab in
                TabBarPreferences.shared.setHidden(tab, false)
                TabSelectionObserver.shared.selectedTab = tab
            }
        )
    }

    // MARK: - Use Case & ViewModel Factories

    func makeDirectInstallUseCase() -> DirectPackageInstallUseCase {
        directInstallFactory()
    }

    func makeDirectInstallViewModel(
        initialURL: String = "",
        initialMode: DirectInstallMode = .signAndInstall
    ) -> DirectInstallViewModel {
        DirectInstallViewModel(
            initialURL: initialURL,
            initialMode: initialMode,
            useCase: directInstallFactory(),
            platform: platform
        )
    }

    func makeFirmwareDownloadUseCase() -> FirmwareDownloadUseCase {
        firmwareDownloadFactory()
    }

    func makeFirmwareBrowserViewModel() -> FirmwareBrowserViewModel {
        FirmwareBrowserViewModel(
            useCase: firmwareDownloadFactory(),
            platform: platform
        )
    }

    func makeWorkspaceResetUseCase() -> WorkspaceResetUseCase {
        WorkspaceResetUseCase(resetStore: resetStore, platform: platform)
    }

    func makeDeepLinkRouter() -> DeepLinkRouterUseCase {
        deepLinkRouterFactory()
    }

    func makeDownloadsTabViewModel() -> DownloadsTabViewModel {
        DownloadsTabViewModel(
            downloadedFiles: downloadedFiles,
            securityPolicy: securityPolicy,
            platform: platform
        )
    }

    func makeDiagnosticsViewModel() -> DiagnosticsCenterViewModel {
        DiagnosticsCenterViewModel(
            provider: diagnosticsProvider,
            platform: platform
        )
    }

    func makeHiddenAppsViewModel() -> HiddenAppsVaultViewModel {
        HiddenAppsVaultViewModel(privacyManager: privacyManager)
    }

    func makeSpecificAppLockViewModel() -> SpecificAppLockViewModel {
        SpecificAppLockViewModel(privacyManager: privacyManager)
    }

    func makeFavoritesAutoUpdatesViewModel() -> FavoritesAutoUpdatesViewModel {
        FavoritesAutoUpdatesViewModel(
            certificateCatalog: certificateCatalog,
            privacyManager: privacyManager
        )
    }

    func makeCertificatesCoordinator() -> CertificatesViewCoordinator {
        CertificatesViewCoordinator(
            certificateCatalog: certificateCatalog,
            platform: platform
        )
    }

    func makeAnisetteProviderUseCase() -> AnisetteProviderUseCase {
        AnisetteProviderUseCase()
    }

    func makeWorkspaceSupportUseCase() -> WorkspaceSupportUseCase {
        WorkspaceSupportUseCase(
            platform: platform,
            environment: workspaceSupportEnvironment
        )
    }

    func makeHomeActionCoordinator(onQuickSignReady: @escaping (AnyApp) -> Void) -> HomeActionCoordinator {
        HomeActionCoordinator(
            securityPolicy: securityPolicy,
            platform: platform,
            enqueuePackageHandler: { [homePackageEnqueue] url, quickSign in
                if quickSign {
                    PackageImportService.importPackage(url) { result in
                        switch result {
                        case .success(let app):
                            Task { @MainActor in
                                ImportDuplicateReview.resolve(app) { chosen, _ in
                                    Toast.success(.localized("App ready to sign"), systemImage: "signature")
                                    onQuickSignReady(AnyApp(base: chosen))
                                }
                            }
                        case .failure(let error):
                            Toast.error(error.localizedDescription, duration: .long)
                        }
                    }
                } else {
                    homePackageEnqueue(url, false)
                }
            },
            startURLDownloadHandler: homeURLDownload,
            revealTabHandler: homeRevealTab
        )
    }
}
