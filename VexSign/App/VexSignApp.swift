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
    }

    /// The UI-test runner passes this flag so a fresh simulator starts on the
    /// working app instead of behind the optional first-run wizard. It only
    /// skips onboarding; it does not fake a certificate, install or test result.
    private var isUIAutomationLaunch: Bool {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "-vexsign-ui-tests"),
              flag + 1 < arguments.count else { return false }
        return arguments[flag + 1] == "1"
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
                    .appAnimation(
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
            .overlay {
                // The switcher snapshot is taken on the way to `.background`, i.e.
                // before App Lock engages. Obscure at `.inactive`, one phase earlier,
                // so the frame iOS keeps is never the Library.
                // The lock screen is already opaque and already the right thing to
                // show, so the cover only fills the gap between `.inactive` and it.
                if scenePhase != .active,
                   appLock.isMasterLockEnabled,
                   !appLock.isLocked,
                   !appLock.isAuthenticating {
                    PrivacySnapshotCover()
                        .zIndex(100)
                }
            }
            .appAnimation(.easeInOut(duration: 0.18), value: appLock.isLocked)
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
                if isUIAutomationLaunch {
                    _onboardingCompleted = true
                } else if !_onboardingCompleted {
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
            // The offer the router staged is presented from a modifier that observes
            // the inbox itself, so this scene's chain stays type-checkable.
            .modifier(SharedBackupPresentation(inbox: appContainer.sharedBackups))
            // One injection point for the whole graph; see AppEnvironment.
            .modifier(AppEnvironment(container: appContainer, appearance: appearance))
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
        // Router entry point for the scene; the container holds the command while
        // the lock covers the app and replays it after unlock.
        appContainer.handleExternalURL(url)
    }
}
