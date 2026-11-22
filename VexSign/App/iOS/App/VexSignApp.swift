//
//  VexSignApp.swift / AppDelegate
//  VexSign
//
//  Created by VexSign Contributors on 10.04.2025.
//

import SwiftUI
import NimbleViews
import IDeviceSwift
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
    /// Observed here, not just owned by the container: a nested `ObservableObject`
    /// does not publish through its parent, so without this the restore sheet would
    /// never present when a file arrives.
    ///
    /// Assigned once in `init` from the container that is already initialised above.
    /// It must not be `@ObservedObject`: that wrapper requires a value at
    /// initialisation, and reading a property initialiser from `init` is illegal.
    @State private var sharedBackups: SharedBackupInbox
    /// Single observable source of truth for theme/font/animation preferences,
    /// injected into the environment so every view updates on change.
    @StateObject private var appearance = AppearanceStore.shared
    @AppStorage("VexSign.userTintColor") private var customWorkspaceAccent: String?
    @AppStorage("VexSign.onboardingCompleted") private var _onboardingCompleted = false
    @State private var _showOnboarding = false

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
        AppPreferencesBootstrap.prepare()
        // `appContainer` is a property initialiser, so it is already constructed.
        // `_appContainer` reads it without the wrapper accessor, and this hands the
        // same inbox to the sheet instead of creating a second one.
        _sharedBackups = State(initialValue: _appContainer.wrappedValue.sharedBackups)
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
                            .environmentObject(tabSelection)
                            .onOpenURL(perform: _handleURL)
                            .zIndex(0)

                        // Floating download bubble and overlay (always present to handle its own animations)
                        DownloadBubbleOverlayContainer(downloadManager: downloadManager)
                            .zIndex(1)
                    }
                }
            }
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
                    AppLifecycleCoordinator.enterBackground()
                }
                if newPhase == .active {
                    AppLifecycleCoordinator.enterForeground()
                }
            }
            .task {
                await AppLifecycleCoordinator.launch()
                if !_onboardingCompleted {
                    _showOnboarding = true
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .vexShowOnboarding)) { _ in
                _showOnboarding = true
            }
            .sheet(isPresented: $_showOnboarding) {
                OnboardingView()
            }
            .sheet(isPresented: $selfUpdate.presentUpdatePrompt) {
                if let release = selfUpdate.available {
                    SelfUpdateSheet(release: release)
                }
            }
            // A backup handed to the app from outside belongs to the app, not to a
            // tab: presenting it here means a share-sheet, AirDrop or Files "Open in"
            // cannot be silently dropped behind a screen the user is not looking at.
            // Bound to the published value, not through a writable key path: the
            // inbox owns `staged` and exposes `stage`/`clear` so dismissal cannot
            // silently drop an offer the user has not answered yet.
            .sheet(item: sharedBackups.staged) { staged in
                // No inner environment scope: the root scope below wraps every
                // presentation, and adding a second one here is the exact drift the
                // workspace boundary gate rejects.
                SharedBackupRestoreSheet(
                    staged: staged,
                    onDiscard: { appContainer.sharedBackups.clear(staged.id) }
                )
            }
            // Keep the dependency scope outside every overlay and presentation.
            // An environment modifier only reaches the subtree before it: the
            // always-built installation pill must receive its queue even idle.
            .environmentObject(appContainer)
            .environmentObject(appContainer.cloudConfiguration)
            .environmentObject(appContainer.tasks)
            .environmentObject(appContainer.appleAccount)
            .environmentObject(appContainer.workspace)
            .environmentObject(appContainer.sources)
            .environmentObject(appContainer.certificates)
            .environmentObject(appContainer.signingPreferences)
            .environmentObject(appContainer.discovery)
            .environmentObject(appContainer.installationQueue)
            .environmentObject(appContainer.files)
            .environmentObject(appContainer.tweaks)
            .environmentObject(appContainer.entitlements)
            .environmentObject(appContainer.repositoryBuilder)
            .environmentObject(appContainer.fileBrowser)
            .environment(\.appContainer, appContainer)
            .environmentObject(appearance)
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
