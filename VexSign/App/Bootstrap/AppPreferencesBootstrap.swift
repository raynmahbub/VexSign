import Foundation

/// Idempotent nonsecret preferences migration/default registration.
@MainActor
enum AppPreferencesBootstrap {
    static func prepare() {
        // Migrate old UserDefaults keys (Feather/Ryuk) to new VexSign keys to preserve features for existing users
        migrateLegacyUserDefaults()

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

    private static func migrateLegacyUserDefaults() {
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

}
