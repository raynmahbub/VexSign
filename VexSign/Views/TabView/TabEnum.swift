//
//  TabEnum.swift
//  VexSign — Library · App Store · Home · Downloads · Settings
//  App Store merges Sources; single navigation bar per tab; Logs moved to Settings.
//
import SwiftUI
import NimbleViews
import NimbleExtensions

enum TabEnum: String, CaseIterable, Hashable, Codable {
    // Main destinations (Files is optional)
    case files
    case library
    case home
    case appStore
    case downloads
    case settings
    // Legacy / hidden — kept for migration, not in default bar. Logs lives in Settings.
    case sources
    case logs
    case tweaks
    case certificates

    var title: String {
        switch self {
        case .files:        return .localized("Files")
        case .library:      return .localized("Library")
        case .home:         return .localized("Home")
        case .appStore:     return .localized("App Store")
        case .downloads:    return .localized("Activity")
        case .settings:     return .localized("Settings")
        // legacy titles (still localized if user has them hidden)
        case .sources:      return .localized("Sources")
        case .logs:         return .localized("Logs")
        case .tweaks:       return .localized("Tweaks")
        case .certificates: return .localized("Certificates")
        }
    }

    var icon: String {
        switch self {
        case .files:        return "folder.fill"
        case .library:      return "square.grid.2x2.fill"
        case .home:         return "house.fill"
        case .appStore:     return "bag.fill" // Apple App Store bag — official-like
        case .downloads:    return "arrow.down.circle.fill"
        case .settings:     return "gearshape.2.fill"
        case .sources:      return "globe.desk.fill"
        case .logs:         return "list.bullet.rectangle.fill"
        case .tweaks:       return "wrench.and.screwdriver.fill"
        case .certificates: return "checkmark.seal.fill"
        }
    }

    var iconOutline: String {
        switch self {
        case .files:        return "folder"
        case .library:      return "square.grid.2x2"
        case .home:         return "house"
        case .appStore:     return "bag"
        case .downloads:    return "arrow.down.circle"
        case .settings:     return "gearshape.2"
        case .sources:      return "globe.desk"
        case .logs:         return "list.bullet.rectangle"
        case .tweaks:       return "wrench.and.screwdriver"
        case .certificates: return "checkmark.seal"
        }
    }

    @ViewBuilder
    static func view(for tab: TabEnum) -> some View {
        switch tab {
        case .files:        FilesTabView()
        case .library:      LibraryWorkspaceView()
        case .home:         HomeView()
        case .appStore:     AppStoreView()
        case .downloads:    ActivityWorkspaceView()
        case .settings:     SettingsView()
        // legacy destinations retained for deep links and data migration
        case .sources:      SourcesView()
        case .logs:         LogsView()
        case .tweaks:       TweaksView()
        case .certificates: NBNavigationView(.localized("Certificates")) { CertificatesView() }
        }
    }

    /// Five defaults, including Home; Files remains available as an optional tab.
    static var defaultTabs: [TabEnum] {
        [.library, .appStore, .home, .downloads, .settings]
    }

    /// Legacy/secondary destinations: the only customizable tabs. They appear
    /// after the five primary tabs when the user surfaces them in
    /// Settings → Tab Bar (deep links and migration also rely on this list).
    static var customizableTabs: [TabEnum] {
        [.files, .sources, .logs, .tweaks, .certificates]
    }
}
