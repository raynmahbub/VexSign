//
//  AppNavigationManager.swift
//  VexSign
//
//  Navigation manager for handling app scrolling and tab switching
//

import Foundation
import SwiftUI
import Combine

// MARK: - App Navigation Manager
class AppNavigationManager: ObservableObject {
    static let shared = AppNavigationManager()
    
    @Published var pendingAppNavigation: PendingAppNavigation?
    
    private var navigationTimer: Timer?
    private var lastNavigationTime: Date = .distantPast
    private let navigationDebounceInterval: TimeInterval = 1.0
    
    private init() {}
    
    struct PendingAppNavigation: Equatable {
        let appId: String
        let appName: String
        let sourceIdentifier: String?
        let navigationId: String = UUID().uuidString
        let timestamp: Date = Date()
        
        static func == (lhs: PendingAppNavigation, rhs: PendingAppNavigation) -> Bool {
            return lhs.appId == rhs.appId
        }
    }
    
    func navigateToApp(appId: String, appName: String, sourceIdentifier: String? = nil) {
        let now = Date()
        guard now.timeIntervalSince(lastNavigationTime) > navigationDebounceInterval else {
            return
        }
        
        lastNavigationTime = now
        
        clearPendingNavigation()
        
        pendingAppNavigation = PendingAppNavigation(
            appId: appId,
            appName: appName,
            sourceIdentifier: sourceIdentifier
        )
        
        // Sources is a legacy storage name. The user-facing destination is the
        // App Store tab, which now owns repository browsing and app discovery.
        TabSelectionObserver.shared.selectedTab = .appStore
        
        navigationTimer?.invalidate()
        navigationTimer = Timer.scheduledTimer(withTimeInterval: 6.0, repeats: false) { [weak self] _ in
            self?.clearPendingNavigation()
        }
    }

    func navigationCompletedSuccessfully() {
        clearPendingNavigation()
    }
    
    func clearPendingNavigation() {
        pendingAppNavigation = nil
        navigationTimer?.invalidate()
        navigationTimer = nil
    }
    
    func forceNavigateToApp(appId: String, appName: String, sourceIdentifier: String? = nil) {
        clearPendingNavigation()
        navigateToApp(appId: appId, appName: appName, sourceIdentifier: sourceIdentifier)
    }

    /// Opens the IPA Explorer home screen from anywhere (Shortcut / automation).
    func openIPAExplorer() {
        TabSelectionObserver.shared.requestIPAExplorer()
    }
}

extension Notification.Name {
    static let openIPAExplorer = Notification.Name("VexSign.openIPAExplorer")
    static let vexShowOnboarding = Notification.Name("VexSign.showOnboarding")
}
