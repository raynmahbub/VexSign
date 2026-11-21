import Foundation
import Combine
import UIKit
import SwiftUI
import AltSourceKit
import NimbleExtensions

/// Explicit Composition Root & Dependency Container for VexSign.
///
/// Created once at app startup (`AppContainer.live()`) and propagated down SwiftUI via
/// `@Environment(\.appContainer)`. Tests construct isolated instances with fakes/mocks
/// without touching global `.shared` singletons.
@MainActor
final class AppContainer: ObservableObject {
    let cloudConfiguration: CloudConfigurationModel
    let backups: BackupWorkspaceUseCase
    /// Backups handed to the app from Files/AirDrop/“Open in”. Presented once at the
    /// root so a staged file cannot be lost behind a tab the user never visits.
    let sharedBackups = SharedBackupInbox()
    let tasks: TaskWorkspaceModel
    let appleAccount: AppleAccountWorkspaceModel
    let analytics: LocalAnalyticsUseCase
    let companion: CompanionArchiveModel
    let repositoryBuilder: RepositoryBuilderViewModel
    let entitlements: EntitlementsWorkspaceModel
    let tweaks: TweakWorkspaceModel
    let files: FileWorkspaceModel
    let fileBrowser: FileBrowserViewModel
    let archives: ArchiveCatalogModel
    private let fileUseCase: FileWorkspaceUseCase
    let workspace: WorkspaceViewModel
    let library: LibraryWorkspaceModel
    let sources: SourcesViewModel
    let repositories: RepositoryManagementModel
    let signing: SigningWorkspaceModel
    let installationQueue: InstallationQueueModel
    let installation: LibraryInstallationModel
    let certificates: CertificateWorkspaceModel
    let signingPreferences: SigningPreferencesModel
    let discovery: DiscoveryViewModel

    let securityPolicy: SecurityPolicyValidating
    let transferService: SecureTransferProviding
    let platform: PlatformSystemAdapting
    let resetStore: WorkspaceResetting
    let downloadedFiles: DownloadedFilesManaging
    let diagnosticsProvider: DiagnosticsProviding
    let privacyManager: AppPrivacyManaging
    let certificateCatalog: CertificateCatalogProviding
    let workspaceSupportEnvironment: WorkspaceSupportEnvironmentProviding

    private let batchProvider: () -> any BatchSigningProviding<UIImage>
    private let anisetteProvider: AnisetteConfigurationProviding
    private let directInstallFactory: () -> DirectPackageInstallUseCase
    private let firmwareDownloadFactory: () -> FirmwareDownloadUseCase
    private let deepLinkRouterFactory: () -> DeepLinkRouterUseCase
    private let homePackageEnqueue: (URL, Bool) -> Void
    private let homeURLDownload: (URL) -> Bool
    private let homeRevealTab: (TabEnum) -> Void

    init(
        workspaceRepository: any WorkspaceCatalogProviding & LibraryRepository,
        libraryCloning: LibraryCloningProviding,
        fileWorkspace: FileWorkspaceProviding,
        tweakWorkspace: TweakWorkspaceProviding,
        entitlementsWorkspace: EntitlementsWorkspaceProviding,
        cloudConfiguration: CloudConfigurationProviding,
        backupWorkspace: BackupWorkspaceProviding,
        taskWorkspace: TaskWorkspaceProviding,
        analytics: LocalAnalyticsProviding,
        appleAccount: AppleAccountWorkspaceProviding,
        companion: CompanionArchivePreparing,
        repositoryDocuments: RepositoryDocumentsProviding,
        archiveCatalog: ArchiveWorkspaceCatalogProviding,
        repositoryCatalog: any RepositoryCatalogProviding<ASRepository>,
        repositoryManagement: any RepositoryManagementProviding<ASRepository>,
        librarySigning: any LibrarySigningProviding<UIImage>,
        libraryInstallation: LibraryInstallationProviding,
        installationQueue: InstallationQueueProviding,
        certificateWorkspace: CertificateWorkspaceProviding,
        signingPreferences: SigningPreferencesProviding,
        discovery: DiscoveryCatalogProviding,
        batchProvider: @escaping () -> any BatchSigningProviding<UIImage>,
        securityPolicy: SecurityPolicyValidating,
        transferService: SecureTransferProviding,
        platform: PlatformSystemAdapting,
        resetStore: WorkspaceResetting,
        downloadedFiles: DownloadedFilesManaging,
        diagnosticsProvider: DiagnosticsProviding,
        privacyManager: AppPrivacyManaging,
        certificateCatalog: CertificateCatalogProviding,
        workspaceSupportEnvironment: WorkspaceSupportEnvironmentProviding,
        anisetteProvider: AnisetteConfigurationProviding,
        directInstallFactory: @escaping () -> DirectPackageInstallUseCase,
        firmwareDownloadFactory: @escaping () -> FirmwareDownloadUseCase,
        deepLinkRouterFactory: @escaping () -> DeepLinkRouterUseCase,
        homePackageEnqueue: @escaping (URL, Bool) -> Void,
        homeURLDownload: @escaping (URL) -> Bool,
        homeRevealTab: @escaping (TabEnum) -> Void
    ) {
        self.cloudConfiguration = CloudConfigurationModel(useCase: CloudConfigurationUseCase(provider: cloudConfiguration))
        self.backups = BackupWorkspaceUseCase(provider: backupWorkspace)
        self.tasks = TaskWorkspaceModel(useCase: TaskWorkspaceUseCase(provider: taskWorkspace))
        self.appleAccount = AppleAccountWorkspaceModel(useCase: AppleAccountWorkspaceUseCase(provider: appleAccount))
        self.analytics = LocalAnalyticsUseCase(provider: analytics)
        self.companion = CompanionArchiveModel(useCase: CompanionArchiveUseCase(provider: companion))
        self.repositoryBuilder = RepositoryBuilderViewModel(useCase: RepositoryBuilderUseCase(provider: repositoryDocuments))
        self.entitlements = EntitlementsWorkspaceModel(useCase: EntitlementsWorkspaceUseCase(provider: entitlementsWorkspace))
        self.tweaks = TweakWorkspaceModel(useCase: TweakWorkspaceUseCase(provider: tweakWorkspace))
        let fileUseCase = FileWorkspaceUseCase(provider: fileWorkspace)
        self.fileUseCase = fileUseCase
        self.files = FileWorkspaceModel(useCase: fileUseCase)
        self.fileBrowser = FileBrowserViewModel(useCase: fileUseCase)
        self.archives = ArchiveCatalogModel(useCase: ArchiveWorkspaceCatalogUseCase(provider: archiveCatalog))
        let workspace = WorkspaceViewModel(useCase: WorkspaceCatalogUseCase(repository: workspaceRepository))
        self.workspace = workspace
        self.library = LibraryWorkspaceModel(useCase: LibraryUseCase(repository: workspaceRepository, cloning: libraryCloning), workspace: workspace, platform: platform)
        self.sources = SourcesViewModel(useCase: RepositoryCatalogUseCase(provider: repositoryCatalog))
        self.repositories = RepositoryManagementModel(useCase: RepositoryManagementUseCase(provider: repositoryManagement, policy: securityPolicy), workspace: workspace, platform: platform)
        self.signing = SigningWorkspaceModel(useCase: SigningWorkspaceUseCase(provider: librarySigning), platform: platform)
        self.installationQueue = InstallationQueueModel(useCase: ObserveInstallationQueueUseCase(provider: installationQueue))
        self.installation = LibraryInstallationModel(useCase: InstallLibraryAppUseCase(provider: libraryInstallation), platform: platform)
        self.certificates = CertificateWorkspaceModel(useCase: CertificateWorkspaceUseCase(provider: certificateWorkspace), workspace: workspace, platform: platform)
        self.signingPreferences = SigningPreferencesModel(useCase: SigningPreferencesUseCase(provider: signingPreferences), platform: platform)
        self.batchProvider = batchProvider
        self.discovery = DiscoveryViewModel(useCase: DiscoveryUseCase(provider: discovery, policy: securityPolicy))
        self.securityPolicy = securityPolicy
        self.transferService = transferService
        self.platform = platform
        self.resetStore = resetStore
        self.downloadedFiles = downloadedFiles
        self.diagnosticsProvider = diagnosticsProvider
        self.privacyManager = privacyManager
        self.certificateCatalog = certificateCatalog
        self.workspaceSupportEnvironment = workspaceSupportEnvironment
        self.anisetteProvider = anisetteProvider
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
        let routingDiagnostics = RoutingDiagnosticsAdapter()
        let incomingFiles = CoordinatedIncomingFilesAdapter(diagnostics: routingDiagnostics)
        let workspaceRepository = CoreDataWorkspaceRepository(storage: Storage.shared)
        let repositories = RepositoryWorkspaceAdapter(catalog: SourceCatalogStore.shared, repository: workspaceRepository)
        let sharing = UIKitTemporaryFileSharing()
        let certificateWorkspace = CertificateWorkspaceAdapter(repository: workspaceRepository, sharing: sharing)

        let container = AppContainer(
            workspaceRepository: workspaceRepository,
            libraryCloning: LibraryCloningAdapter(repository: workspaceRepository, cloner: AppCloner.shared),
            fileWorkspace: FileWorkspaceAdapter(repository: workspaceRepository, sharing: sharing),
            tweakWorkspace: TweakWorkspaceAdapter(manager: TweakManager.shared, repository: workspaceRepository),
            entitlementsWorkspace: EntitlementsWorkspaceAdapter(manager: EntitlementsManager.shared),
            cloudConfiguration: CloudConfigurationAdapter(client: CloudSigningClient.shared),
            backupWorkspace: BackupWorkspaceAdapter(manager: BackupManager.shared),
            taskWorkspace: TaskWorkspaceAdapter(center: UnifiedTaskCenter.shared, downloads: DownloadManager.shared),
            analytics: LocalAnalyticsAdapter(),
            appleAccount: AppleAccountWorkspaceAdapter(manager: NativeSigningManager.shared, repository: workspaceRepository),
            companion: CompanionArchiveAdapter(repository: workspaceRepository, sharing: sharing),
            repositoryDocuments: RepositoryDocumentsAdapter(),
            archiveCatalog: ArchiveWorkspaceCatalogAdapter(repository: workspaceRepository),
            repositoryCatalog: repositories,
            repositoryManagement: repositories,
            librarySigning: LibrarySigningAdapter(repository: workspaceRepository),
            libraryInstallation: LibraryInstallationAdapter(storage: Storage.shared),
            installationQueue: InstallationQueueAdapter(queue: InstallQueue.shared, repository: workspaceRepository),
            certificateWorkspace: certificateWorkspace,
            signingPreferences: SigningPreferencesAdapter(sharing: sharing),
            discovery: RepositoryDiscoveryAdapter(catalog: SourceCatalogStore.shared, storage: Storage.shared, downloads: DownloadManager.shared, security: security),
            batchProvider: { BatchSigningAdapter(repository: workspaceRepository) },
            securityPolicy: security,
            transferService: transfer,
            platform: platform,
            resetStore: resetStore,
            downloadedFiles: downloadedFiles,
            diagnosticsProvider: diagnostics,
            privacyManager: privacy,
            certificateCatalog: certCatalog,
            workspaceSupportEnvironment: workspaceSupport,
            anisetteProvider: NativeAnisetteConfigurationAdapter(),
            directInstallFactory: {
                DirectPackageInstallUseCase(
                    securityPolicy: security,
                    transferService: transfer,
                    maximumPackageBytes: DownloadIntegrity.maximumPackageBytes,
                    installation: DirectPackageInstallationAdapter()
                )
            },
            firmwareDownloadFactory: {
                FirmwareDownloadUseCase(
                    securityPolicy: security,
                    transferService: transfer,
                    firmwareDirectory: FileManager.default.firmware,
                    fileExists: { FileManager.default.fileExists(atPath: $0.path) },
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
                    incomingFiles: incomingFiles,
                    diagnostics: routingDiagnostics,
                    decodeBase64File: { base64, suffix in
                        FileManager.default.decodeAndWrite(base64: base64, pathComponent: suffix)
                    },
                    validateCertificatePassword: { p12, password, provision in
                        CertificateManagementService.validateSigningPair(for: p12, with: password, using: provision)
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
                    },
                    stageBackupFile: { url in
                        sharedBackups.stage(url)
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
        InstallQueueWindow.shared.configure(makeRootView: {
            AnyView(InstallQueueHostView(queue: container.installationQueue)
                .environmentObject(container).environmentObject(container.workspace)
                .environmentObject(container.sources).environmentObject(container.certificates)
                .environmentObject(container.signingPreferences).environmentObject(container.discovery)
                .environmentObject(container.installationQueue).environmentObject(container.files)
                .environmentObject(container.cloudConfiguration).environmentObject(container.tasks).environmentObject(container.appleAccount).environmentObject(container.fileBrowser).environmentObject(container.tweaks).environmentObject(container.entitlements).environmentObject(container.repositoryBuilder).environment(\.appContainer, container))
        }, mayTeardown: { InstallQueue.shared.current == nil })
        return container
    }

    // MARK: - Use Case & ViewModel Factories

    func makeBatchWorkflow(apps: [AppInfoPresentable], mode: BatchSigningMode, options: Options,
                           overrides: [String: Options] = [:], icons: [String: UIImage] = [:],
                           certificate: CertificateRecord?, resignsSigned: Bool = true) -> BatchWorkflowModel? {
        do {
            let request = BatchSigningRequest(apps: try apps.map { try LibraryAppReference(app: $0) }, mode: mode,
                options: options, overrides: overrides, icons: icons, certificateID: certificate?.id, resignsSigned: resignsSigned)
            let useCase = try BatchSigningUseCase(provider: batchProvider(), request: request)
            return try BatchWorkflowModel(useCase: useCase, mode: mode)
        } catch { platform.notifyError(error.localizedDescription, sticky: true); return nil }
    }

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
            certificates: certificates,
            certificateCatalog: certificateCatalog,
            platform: platform
        )
    }

    func makeAnisetteProviderUseCase() -> AnisetteProviderUseCase {
        AnisetteProviderUseCase(provider: anisetteProvider)
    }

    func makeAnisetteSettingsViewModel() -> AnisetteSettingsViewModel {
        AnisetteSettingsViewModel(useCase: makeAnisetteProviderUseCase())
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
            files: fileUseCase,
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
