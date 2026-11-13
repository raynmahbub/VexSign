//
//  VexSignApp.swift / AppDelegate
//  VexSign
//
//  Created by VexSign Contributors on 10.04.2025.
//

import SwiftUI
import NimbleViews
import IDeviceSwift
import BackgroundTasks
import OSLog
import NimbleExtensions

@main
struct VexSignApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    let heartbeat = HeartbeatManager.shared

    @StateObject private var appContainer = AppContainer.live()
    @StateObject var downloadManager = DownloadManager.shared
    @StateObject private var tabSelection = TabSelectionObserver.shared
    @StateObject private var selfUpdate = SelfUpdateManager.shared
    @StateObject private var appLock = AppLockManager.shared
    /// Single observable source of truth for theme/font/animation preferences,
    /// injected into the environment so every view updates on change.
    @StateObject private var appearance = AppearanceStore.shared
    @AppStorage("VexSign.userTintColor") private var customWorkspaceAccent: String?
    @AppStorage("VexSign.onboardingCompleted") private var _onboardingCompleted = false
    @State private var _showOnboarding = false
    let storage = Storage.shared

    private var activeManualDownloads: [Download] {
        downloadManager.manualDownloads.filter {
            $0.isActive || $0.progress > 0 || $0.unpackageProgress > 0
        }
    }

    private var activeNonManualDownloads: [Download] {
        downloadManager.nonManualDownloads.filter {
            $0.isActive || $0.progress > 0 || $0.unpackageProgress > 0
        }
    }

    private var hasActiveDownloads: Bool {
        !activeManualDownloads.isEmpty || !activeNonManualDownloads.isEmpty
    }

    init() {
        // Migrate old UserDefaults keys (Feather/Ryuk) to new VexSign keys to preserve features for existing users
        Self._migrateLegacyUserDefaults()

        UserDefaults.standard.register(defaults: [
            "VexSign.serverMethod": 0, // Fully Local signing
            "VexSign.backgroundDownloadHeaderStartState": "collapsed",
            "VexSign.showDownloadHeaderInSourcesTab": true,
            "VexSign.downloadDisplayMode": "floating", // Default to floating icon
            "VexSign.sourcesShowUpdatesAsTab": true,
            "VexSign.downloadOverlayTheme": "darkGrey",
            "VexSign.dynamicOverlaySize": true,
            // Master cleanup switch: on, with every sub-toggle off, so updating the app
            // never changes what gets deleted. See Settings → Auto Cleanup.
            CleanupManager.Key.enabled: true
        ])

        // Liquid Glass is adopted the supported way: the views that want the material ask
        // for it through availability-checked APIs (`glassEffect`, `glassBackgroundEffect`).
        // The app previously forced the redesign on by writing SwiftUI's undocumented
        // `com.apple.SwiftUI.IgnoreSolariumLinkedOnCheck` preference; a key Apple never
        // documented can change meaning or vanish between releases. A build that wrote it
        // may still have the stale value in its container, so it is cleared once here.
        UserDefaults.standard.removeObject(forKey: "com.apple.SwiftUI.IgnoreSolariumLinkedOnCheck")
    }

    private static func _migrateLegacyUserDefaults() {
        let oldToNew: [String: String] = [
            "feather.selectedCert": "vexsign.selectedCert",
            "Feather.serverMethod": "VexSign.serverMethod",
            "Feather.backgroundDownloadHeaderStartState": "VexSign.backgroundDownloadHeaderStartState",
            "Feather.showDownloadHeaderInSourcesTab": "VexSign.showDownloadHeaderInSourcesTab",
            "Feather.downloadDisplayMode": "VexSign.downloadDisplayMode",
            "Feather.sourcesShowUpdatesAsTab": "VexSign.sourcesShowUpdatesAsTab",
            "Feather.downloadOverlayTheme": "VexSign.downloadOverlayTheme",
            "Feather.dynamicOverlaySize": "VexSign.dynamicOverlaySize",
            "Feather.userInterfaceStyle": "VexSign.userInterfaceStyle",
            "RyukSign.onboardingCompleted": "VexSign.onboardingCompleted"
        ]
        for (oldKey, newKey) in oldToNew {
            if UserDefaults.standard.object(forKey: newKey) == nil,
               let oldValue = UserDefaults.standard.object(forKey: oldKey) {
                UserDefaults.standard.set(oldValue, forKey: newKey)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                let downloadDisplayMode = UserDefaults.standard.string(forKey: "VexSign.downloadDisplayMode") ?? "floating"

                if downloadDisplayMode == "header" {
                    VStack(spacing: 0) {
                        // Single animation point for header presence
                        if !activeManualDownloads.isEmpty || !activeNonManualDownloads.isEmpty {
                            downloadHeaderContent
                                .transition(.move(edge: .top).combined(with: .opacity))
                                .zIndex(1)
                        }

                        TabbarView()
                            .environment(\.managedObjectContext, storage.context)
                            .environmentObject(tabSelection)
                            .onOpenURL(perform: _handleURL)
                            .zIndex(0)
                    }
                    .animation(
                        appearance.animationsEnabled ? .spring(response: 0.4, dampingFraction: 0.8) : nil,
                        value: hasActiveDownloads
                    )
                } else {
                    ZStack {
                        TabbarView()
                            .environment(\.managedObjectContext, storage.context)
                            .environmentObject(tabSelection)
                            .onOpenURL(perform: _handleURL)
                            .zIndex(0)

                        // Floating download bubble and overlay (always present to handle its own animations)
                        DownloadBubbleOverlayContainer(downloadManager: downloadManager)
                            .zIndex(1)
                    }
                }
            }
            .environmentObject(appContainer)
            .environment(\.appContainer, appContainer)
            .environmentObject(appearance)
            .modifier(VexWorkspaceTypography())
            .modifier(VexWorkspaceAccessibility())
            .tint(Theme.tint)
            .environment(\.nbWorkspaceBackground, Theme.background)
            .environment(\.nbWorkspaceCard, Theme.card)
            .preferredColorScheme(appearance.visualTheme.preferredColorScheme)
            .buttonStyle(VexSignFlareButtonStyle(enabled: appearance.animationsEnabled))
            .vexSignWebMotion()
            .overlay(alignment: .bottom) {
                InstallQueuePill()
            }
            .overlay {
                // App Lock: covers everything, including the download bubble, while locked.
                if appLock.isLocked {
                    AppLockScreenView()
                        .transition(.opacity)
                        .zIndex(99)
                }
            }
            .animation(.easeInOut(duration: 0.18), value: appLock.isLocked)
            .onReceive(NotificationCenter.default.publisher(for: .heartbeatInvalidHost)) { _ in
                DispatchQueue.main.async {
                    UIAlertController.showAlertWithOk(
                        title: "InvalidHostID",
                        message: .localized("Your pairing file is invalid and is incompatible with your device, please import a valid pairing file.")
                    )
                }
            }
            .onAppear {
                if let style = UIUserInterfaceStyle(rawValue: UserDefaults.standard.integer(forKey: "VexSign.userInterfaceStyle")) {
                    UIApplication.topViewController()?.view.window?.overrideUserInterfaceStyle = style
                }

                UIApplication.topViewController()?.view.window?.tintColor = UIColor(Theme.tint)
            }
            .nbOnChange(of: customWorkspaceAccent) { _ in
                UIApplication.topViewController()?.view.window?.tintColor = UIColor(Theme.tint)
            }
            .nbOnChange(of: appearance.visualTheme) { _ in
                UIApplication.topViewController()?.view.window?.tintColor = UIColor(Theme.tint)
            }
            .nbOnChange(of: scenePhase) { newPhase in
                if newPhase == .background {
                    EcosystemMaintenance.schedule()
                    appLock.lockIfNeeded()
                }
                if newPhase == .active {
                    Task { @MainActor in
                        SourcesViewModel.shared.resetLoadingState()
                        LibraryStatusStore.shared.refreshKnown()
                        InstallQueue.shared.reconcileOnForeground()
                    }
                    appLock.authenticateIfNeeded()
                }
            }
            .task {
                await selfUpdate.checkOnLaunch()
                await EcosystemMaintenance.run()
                await CertificateExpiryMonitor.checkOnLaunch()
                StorageRules.warnIfOverLimit()
                if !_onboardingCompleted {
                    _showOnboarding = true
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .vexShowOnboarding)) { _ in
                _showOnboarding = true
            }
            .sheet(isPresented: $_showOnboarding) {
                // The wizard reads certificates/sources via @FetchRequest, so
                // it needs the managed object context in its own environment
                // (the sheet does not inherit the tab content's injection).
                OnboardingView()
                    .environment(\.managedObjectContext, storage.context)
                    .environmentObject(appContainer)
                    .environment(\.appContainer, appContainer)
            }
            .sheet(isPresented: $selfUpdate.presentUpdatePrompt) {
                if let release = selfUpdate.available {
                    SelfUpdateSheet(release: release)
                        .environmentObject(appContainer)
                        .environment(\.appContainer, appContainer)
                }
            }
        }
    }

    @ViewBuilder
    private var downloadHeaderContent: some View {
        if !activeManualDownloads.isEmpty {
            DownloadHeaderView(downloadManager: downloadManager)
        } else if !activeNonManualDownloads.isEmpty {
            let showInSourcesTab = UserDefaults.standard.bool(forKey: "VexSign.showDownloadHeaderInSourcesTab")
            let shouldHide = tabSelection.selectedTab == .appStore && !showInSourcesTab

            if !shouldHide {
                ConditionalDownloadHeaderView(downloads: activeNonManualDownloads)
            }
        }
    }

    private func _handleURL(_ url: URL) {
        appContainer.makeDeepLinkRouter().handle(url)
    }
}

class AppDelegate: NSObject, UIApplicationDelegate, DownloadManager.ErrorDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Create the store here, on the main thread, before anything else can
        // reach for it: the certificate importer starts from a utility queue a
        // few lines down, and whoever touches `Storage.shared` first is the
        // thread that creates the container.
        _ = Storage.shared

        // Anything still held from an "Undo" offer in an earlier session was never undone.
        RecoverableFileRemoval.sweep()

        BackgroundAndLifecyclePlatform.configureImagePipeline()
        BackgroundAndLifecyclePlatform.ensureDocumentsDirectories()
        StorageManager.purgeStaleTemporary()
        Storage.shared.recoverPendingAppDeletions()
        InstallCleanup.flushOnLaunch()
        _addDefaultCertificates()
        _registerBackgroundTasks()
        EcosystemMaintenance.register()
        EcosystemMaintenance.schedule()
        scheduleAutomationMaintenance()

        // Apple Watch companion: a no-op unless the user switched it on.
        CompanionBridge.shared.activateIfNeeded()

        // Idempotent, no-op after first run.
        VexSignAPI.migrateIfNeeded()

        // Attach the premium repository API key to every manifest fetch/decrypt request.
        RepositoryCatalogService.registerRepositoryKeyProvider()

        DownloadManager.shared.errorDelegate = self

        return true
    }

    // MARK: - DownloadManager.ErrorDelegate

    func showUIErrorMessage(title: String, message: String) {
        DispatchQueue.main.async {
            UIAlertController.showErrorWithCopy(
                title: .localized(title),
                message: message
            )
        }
    }

    /// A download that failed its integrity check needs an answer, not an acknowledgement —
    /// the file is either imported deliberately or deleted.
    func showUIErrorMessage(
        title: String,
        message: String,
        actionTitle: String,
        action: @escaping () -> Void,
        dismissTitle: String,
        onDismiss: (() -> Void)?
    ) {
        DispatchQueue.main.async {
            UIAlertController.showAlertWithOptions(
                title: .localized(title),
                message: message,
                actions: [
                    (actionTitle, .default, action),
                    (dismissTitle, .cancel, onDismiss)
                ]
            )
        }
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        DownloadManager.shared.backgroundCompletionHandler = completionHandler
    }

    private func _addDefaultCertificates() {
        CertificateAutoImporter.shared.importBundledCertificatesIfNeeded()
    }
}
