import Foundation
import NimbleExtensions

enum SettingsSearchRoute: String, CaseIterable {
    case setupHealth
    case certificates
    case signingOptions
    case advancedSigning
    case signingProfiles
    case compression
    case installation
    case automation
    case shortcuts
    case appearance
    case appIcon
    case tabBar
    case notifications
    case refresh
    case downloads
    case updateMatching
    case autoUpdates
    case appUpdates
    case appLock
    case specificAppLock
    case hiddenApps
    case antiRevoke
    case expiryReminders
    case guides
    case jit
    case location
    case webManager
    case ipaExplorer
    case ecosystem
    case cloudSigning
    case companions
    case gameMode
    case diagnostics
    case storage
    case cleanup
    case backup
    case firmware
    case deviceDiagnostics
    case logs
    case reset
    case about
    case featureStatus
    case tweaks
    case companionSigning
    case companionDiagnostics
}

struct SettingsSearchEntry: Identifiable {
    let id: SettingsSearchRoute
    let title: String
    let icon: String
    let keywords: String
}

enum SettingsSearchIndex {
    static var entries: [SettingsSearchEntry] {
[
            SettingsSearchEntry(id: .setupHealth, title: .localized("Setup Health"), icon: "checklist", keywords: "setup health readiness prerequisites"),
            SettingsSearchEntry(id: .certificates, title: .localized("Certificates Manager"), icon: "checkmark.seal.fill", keywords: "p12 mobileprovision profile expiry certificate"),
            SettingsSearchEntry(id: .signingOptions, title: .localized("Signing Options"), icon: "signature", keywords: "signing options"),
            SettingsSearchEntry(id: .advancedSigning, title: .localized("Advanced Signing & Patches"), icon: "cpu.fill", keywords: "advanced signing & patches"),
            SettingsSearchEntry(id: .signingProfiles, title: .localized("Signing Profiles"), icon: "person.crop.rectangle.stack.fill", keywords: "signing profiles"),
            SettingsSearchEntry(id: .compression, title: .localized("Compression & Packaging"), icon: "archivebox.fill", keywords: "compression & packaging"),
            SettingsSearchEntry(id: .installation, title: .localized("Installation Engine"), icon: "arrow.down.app.fill", keywords: "install https tls server trollstore idevice"),
            SettingsSearchEntry(id: .automation, title: .localized("Background Automation"), icon: "bolt.badge.clock.fill", keywords: "automatic refresh renew schedule history background"),
            SettingsSearchEntry(id: .shortcuts, title: .localized("Siri & Shortcuts"), icon: "waveform", keywords: "siri & shortcuts"),
            SettingsSearchEntry(id: .appearance, title: .localized("Appearance"), icon: "paintbrush.fill", keywords: "theme liquid glass font color appearance"),
            SettingsSearchEntry(id: .appIcon, title: .localized("App Icon"), icon: "app.badge.fill", keywords: "app icon"),
            SettingsSearchEntry(id: .tabBar, title: .localized("Tab Bar"), icon: "squares.below.rectangle", keywords: "tab bar"),
            SettingsSearchEntry(id: .notifications, title: .localized("Notifications & Dynamic Island"), icon: "bell.badge.fill", keywords: "notifications & dynamic island"),
            SettingsSearchEntry(id: .refresh, title: .localized("Refresh & Background Sync"), icon: "arrow.clockwise.icloud.fill", keywords: "repository sources sync refresh network"),
            SettingsSearchEntry(id: .downloads, title: .localized("Download Manager"), icon: "arrow.down.circle.fill", keywords: "download manager"),
            SettingsSearchEntry(id: .updateMatching, title: .localized("Update Matching"), icon: "slider.horizontal.3", keywords: "update matching"),
            SettingsSearchEntry(id: .autoUpdates, title: .localized("Favorites & Auto Updates"), icon: "star.circle.fill", keywords: "favorites & auto updates"),
            SettingsSearchEntry(id: .appUpdates, title: .localized("App Updates"), icon: "sparkles", keywords: "app updates"),
            SettingsSearchEntry(id: .appLock, title: .localized("Master App Lock"), icon: "lock.iphone", keywords: "master app lock"),
            SettingsSearchEntry(id: .specificAppLock, title: .localized("Specific App Lock"), icon: "lock.fill", keywords: "specific app lock"),
            SettingsSearchEntry(id: .hiddenApps, title: .localized("Hidden Apps Vault"), icon: "eye.slash.fill", keywords: "hidden apps vault"),
            SettingsSearchEntry(id: .antiRevoke, title: .localized("Anti-Revoke & DNS Shield"), icon: "shield.checkered", keywords: "anti-revoke & dns shield"),
            SettingsSearchEntry(id: .expiryReminders, title: .localized("Expiry Reminders"), icon: "bell.badge.fill", keywords: "expiry reminders"),
            SettingsSearchEntry(id: .guides, title: .localized("Guides"), icon: "book.fill", keywords: "guides"),
            SettingsSearchEntry(id: .jit, title: .localized("JIT & On-Device Pairing"), icon: "bolt.badge.automatic.fill", keywords: "jit pairing vpn tunnel"),
            SettingsSearchEntry(id: .location, title: .localized("Location Simulator"), icon: "location.fill", keywords: "location simulator"),
            SettingsSearchEntry(id: .webManager, title: .localized("Web Manager & File Server"), icon: "externaldrive.badge.wifi", keywords: "wifi webdav browser upload server"),
            SettingsSearchEntry(id: .ipaExplorer, title: .localized("IPA Explorer"), icon: "doc.text.magnifyingglass", keywords: "ipa explorer"),
            SettingsSearchEntry(id: .ecosystem, title: .localized("Ecosystem"), icon: "square.stack.3d.up.fill", keywords: "ecosystem"),
            SettingsSearchEntry(id: .cloudSigning, title: .localized("Cloud Signing"), icon: "cloud.fill", keywords: "cloud signing"),
            SettingsSearchEntry(id: .companions, title: .localized("Companion Devices"), icon: "applewatch", keywords: "companion devices"),
            SettingsSearchEntry(id: .gameMode, title: .localized("Game Mode"), icon: "gamecontroller.fill", keywords: "game mode"),
            SettingsSearchEntry(id: .diagnostics, title: .localized("Diagnostics Center"), icon: "cross.case.fill", keywords: "diagnostics center"),
            SettingsSearchEntry(id: .storage, title: .localized("Storage Breakdown"), icon: "internaldrive.fill", keywords: "storage breakdown"),
            SettingsSearchEntry(id: .cleanup, title: .localized("Auto Cleanup & Cache"), icon: "sparkles", keywords: "auto cleanup & cache"),
            SettingsSearchEntry(id: .backup, title: .localized("Backup, Transfer & Migration"), icon: "arrow.triangle.2.circlepath", keywords: "backup restore migration transfer"),
            SettingsSearchEntry(id: .firmware, title: .localized("IPSW & Firmware Catalog"), icon: "opticaldisc.fill", keywords: "ipsw & firmware catalog"),
            SettingsSearchEntry(id: .deviceDiagnostics, title: .localized("System Diagnostics"), icon: "info.circle.fill", keywords: "system diagnostics"),
            SettingsSearchEntry(id: .logs, title: .localized("Activity Logs"), icon: "text.alignleft", keywords: "activity logs"),
            SettingsSearchEntry(id: .reset, title: .localized("Reset VexSign"), icon: "trash.fill", keywords: "reset vexsign"),
            SettingsSearchEntry(id: .about, title: .localized("About"), icon: "info.circle", keywords: "about"),
            SettingsSearchEntry(id: .featureStatus, title: .localized("Feature Status"), icon: "checklist", keywords: "feature status"),
            SettingsSearchEntry(id: .companionDiagnostics, title: .localized("Companion Setup Diagnostics"), icon: "stethoscope", keywords: "sidestore livecontainer account renewal pairing vpn jit diagnostics"),
            SettingsSearchEntry(id: .companionSigning, title: .localized("SideStore & LiveContainer"), icon: "arrow.triangle.branch", keywords: "apple account login 2fa sidestore livecontainer renewal guest"),
            SettingsSearchEntry(id: .tweaks, title: .localized("Tweaks & Dylibs"), icon: "wrench.and.screwdriver.fill", keywords: "tweaks & dylibs"),
        ]
    }

    static func matches(_ entry: SettingsSearchEntry, query: String) -> Bool {
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let text = entry.title + " " + entry.keywords
        return terms.allSatisfy { text.localizedStandardContains($0) }
    }
}
