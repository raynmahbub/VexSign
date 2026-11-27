import Foundation

/// Idempotent nonsecret preferences migration/default registration.
@MainActor
enum AppPreferencesBootstrap {
    static func prepare() {
        // Idempotent, injectable upgrade step for old Feather/Ryuk keys.
        LegacyPreferenceMigration.migrate(in: .standard)

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


}
