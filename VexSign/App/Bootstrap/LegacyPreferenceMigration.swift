//
//  LegacyPreferenceMigration.swift
//  VexSign
//
//  Pure, injectable upgrade step for non-secret preferences. It never deletes
//  a key and never overwrites a value already owned by VexSign, so an upgrade
//  (or a retry after an interrupted launch) is safe and deterministic.
//

import Foundation

enum LegacyPreferenceMigration {
    struct KeyPair {
        let legacy: String
        let current: String
    }

    /// Feather/Ryuk keys used by earlier builds, mapped to their VexSign key.
    static let pairs: [KeyPair] = [
        KeyPair(legacy: "feather.selectedCert", current: "vexsign.selectedCert"),
        KeyPair(legacy: "Feather.serverMethod", current: "VexSign.serverMethod"),
        KeyPair(legacy: "Feather.backgroundDownloadHeaderStartState", current: "VexSign.backgroundDownloadHeaderStartState"),
        KeyPair(legacy: "Feather.showDownloadHeaderInSourcesTab", current: "VexSign.showDownloadHeaderInSourcesTab"),
        KeyPair(legacy: "Feather.downloadDisplayMode", current: "VexSign.downloadDisplayMode"),
        KeyPair(legacy: "Feather.sourcesShowUpdatesAsTab", current: "VexSign.sourcesShowUpdatesAsTab"),
        KeyPair(legacy: "Feather.downloadOverlayTheme", current: "VexSign.downloadOverlayTheme"),
        KeyPair(legacy: "Feather.dynamicOverlaySize", current: "VexSign.dynamicOverlaySize"),
        KeyPair(legacy: "Feather.userInterfaceStyle", current: "VexSign.userInterfaceStyle"),
        KeyPair(legacy: "RyukSign.onboardingCompleted", current: "VexSign.onboardingCompleted")
    ]

    /// - Returns: the current keys whose values were adopted in this call.
    @discardableResult
    static func migrate(in defaults: UserDefaults) -> [String] {
        var migrated: [String] = []
        for pair in pairs {
            guard defaults.object(forKey: pair.current) == nil,
                  let legacyValue = defaults.object(forKey: pair.legacy) else { continue }
            defaults.set(legacyValue, forKey: pair.current)
            migrated.append(pair.current)
        }
        return migrated
    }
}
