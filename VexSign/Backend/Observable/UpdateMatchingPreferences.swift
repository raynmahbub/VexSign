//
//  UpdateMatchingPreferences.swift
//  VexSign — App Update Tracking & Matching Preferences
//

import SwiftUI
import Combine
import NimbleExtensions

enum NameMatchingMode: String, CaseIterable, Identifiable, Sendable {
    case off = "Off"
    case exact = "Exact"
    case balanced = "Balanced"
    case loose = "Loose"
    var id: String { rawValue }

    var localizedDescription: String {
        switch self {
        case .off:
            return .localized("Only match apps by exact Bundle Identifier.")
        case .exact:
            return .localized("Match if the app name is identical (case-insensitive).")
        case .balanced:
            return .localized("Match normalized names, ignoring suffixes like “++” or “Pro”.")
        case .loose:
            return .localized("Loose match on substring or similar titles.")
        }
    }
}

enum UpdateMatchingMode: String, CaseIterable, Identifiable {
    case updateMatching = "Update Matching"
    case favoritesOnly = "Favorites Only"
    case allApps = "All Sourced Apps"
    var id: String { rawValue }

    var localizedDescription: String {
        switch self {
        case .updateMatching:
            return .localized("Standard update matching using configured name and source rules.")
        case .favoritesOnly:
            return .localized("Only check and notify updates for apps marked as favorites.")
        case .allApps:
            return .localized("Check updates for all library applications without filtering.")
        }
    }
}

final class UpdateMatchingPreferences: ObservableObject {
    static let shared = UpdateMatchingPreferences()

    // MARK: - Keys for Update Matching
    private let keyNameMatching = "VexSign.updateMatching.nameMode"
    private let keySameDeveloper = "VexSign.updateMatching.sameDeveloper"
    private let keySameSource = "VexSign.updateMatching.sameSource"
    private let keyIncludeBetas = "VexSign.updateMatching.includeBetas"
    private let keyIncludeNoDownload = "VexSign.updateMatching.includeNoDownload"

    // MARK: - Keys for Favorites & Auto Updates
    private let keyMatchingMode = "VexSign.updateMatching.matchingMode"
    private let keyAutoUpdateCert = "VexSign.updateMatching.autoUpdateCert"
    private let keyAutoUpdateEnabled = "VexSign.updateMatching.autoUpdateEnabled"
    private let keyAutoUpdateWifiOnly = "VexSign.updateMatching.autoUpdateWifiOnly"
    private let keyNotifyOnAutoUpdate = "VexSign.updateMatching.notifyOnAutoUpdate"
    private let keyAutoInstallAfterUpdate = "VexSign.updateMatching.autoInstallAfterUpdate"
    private let keyFavoriteApps = "VexSign.updateMatching.favoriteAppUUIDs"
    private let keyAutoUpdateApps = "VexSign.updateMatching.autoUpdateAppUUIDs"
    private let keyAutoUpdateAllowlistActive = "VexSign.updateMatching.autoUpdateAllowlistActive"

    // MARK: - Published Properties: Update Matching
    @Published var nameMatchingMode: NameMatchingMode {
        didSet { UserDefaults.standard.set(nameMatchingMode.rawValue, forKey: keyNameMatching) }
    }

    @Published var sameDeveloper: Bool {
        didSet { UserDefaults.standard.set(sameDeveloper, forKey: keySameDeveloper) }
    }

    @Published var samePlaceItCameFrom: Bool {
        didSet { UserDefaults.standard.set(samePlaceItCameFrom, forKey: keySameSource) }
    }

    @Published var includeBetas: Bool {
        didSet { UserDefaults.standard.set(includeBetas, forKey: keyIncludeBetas) }
    }

    @Published var includeNoDownload: Bool {
        didSet { UserDefaults.standard.set(includeNoDownload, forKey: keyIncludeNoDownload) }
    }

    // MARK: - Published Properties: Favorites & Auto Updates
    @Published var matchingMode: UpdateMatchingMode {
        didSet { UserDefaults.standard.set(matchingMode.rawValue, forKey: keyMatchingMode) }
    }

    @Published var autoUpdateCertificate: String {
        didSet { UserDefaults.standard.set(autoUpdateCertificate, forKey: keyAutoUpdateCert) }
    }

    @Published var isAutoUpdateEnabled: Bool {
        didSet { UserDefaults.standard.set(isAutoUpdateEnabled, forKey: keyAutoUpdateEnabled) }
    }

    @Published var autoUpdateWifiOnly: Bool {
        didSet { UserDefaults.standard.set(autoUpdateWifiOnly, forKey: keyAutoUpdateWifiOnly) }
    }

    @Published var notifyOnAutoUpdate: Bool {
        didSet { UserDefaults.standard.set(notifyOnAutoUpdate, forKey: keyNotifyOnAutoUpdate) }
    }

    @Published var autoInstallAfterUpdate: Bool {
        didSet { UserDefaults.standard.set(autoInstallAfterUpdate, forKey: keyAutoInstallAfterUpdate) }
    }

    @Published var favoriteAppUUIDs: Set<String> {
        didSet { UserDefaults.standard.set(Array(favoriteAppUUIDs), forKey: keyFavoriteApps) }
    }

    @Published var autoUpdateAppUUIDs: Set<String> {
        didSet { UserDefaults.standard.set(Array(autoUpdateAppUUIDs), forKey: keyAutoUpdateApps) }
    }

    /// When false, every eligible library app is allowed. When true, the UUID
    /// set is an explicit allowlist (including the intentional empty set).
    @Published var autoUpdateAllowlistActive: Bool {
        didSet { UserDefaults.standard.set(autoUpdateAllowlistActive, forKey: keyAutoUpdateAllowlistActive) }
    }

    private init() {
        let defaults = UserDefaults.standard

        let savedName = defaults.string(forKey: keyNameMatching) ?? NameMatchingMode.balanced.rawValue
        self.nameMatchingMode = NameMatchingMode(rawValue: savedName) ?? .balanced

        self.sameDeveloper = defaults.bool(forKey: keySameDeveloper)
        self.samePlaceItCameFrom = defaults.bool(forKey: keySameSource)
        self.includeBetas = defaults.bool(forKey: keyIncludeBetas)
        self.includeNoDownload = defaults.bool(forKey: keyIncludeNoDownload)

        let savedMode = defaults.string(forKey: keyMatchingMode) ?? UpdateMatchingMode.updateMatching.rawValue
        self.matchingMode = UpdateMatchingMode(rawValue: savedMode) ?? .updateMatching

        self.autoUpdateCertificate = defaults.string(forKey: keyAutoUpdateCert) ?? "Global Default"

        self.isAutoUpdateEnabled = defaults.object(forKey: keyAutoUpdateEnabled) == nil ? true : defaults.bool(forKey: keyAutoUpdateEnabled)
        self.autoUpdateWifiOnly = defaults.object(forKey: keyAutoUpdateWifiOnly) == nil ? true : defaults.bool(forKey: keyAutoUpdateWifiOnly)
        self.notifyOnAutoUpdate = defaults.object(forKey: keyNotifyOnAutoUpdate) == nil ? true : defaults.bool(forKey: keyNotifyOnAutoUpdate)
        self.autoInstallAfterUpdate = defaults.bool(forKey: keyAutoInstallAfterUpdate)

        let favArray = defaults.stringArray(forKey: keyFavoriteApps) ?? []
        self.favoriteAppUUIDs = Set(favArray)

        let autoArray = defaults.stringArray(forKey: keyAutoUpdateApps) ?? []
        self.autoUpdateAppUUIDs = Set(autoArray)
        self.autoUpdateAllowlistActive = defaults.object(forKey: keyAutoUpdateAllowlistActive) as? Bool ?? !autoArray.isEmpty
    }

    func isFavorite(uuid: String) -> Bool {
        favoriteAppUUIDs.contains(uuid)
    }

    func toggleFavorite(uuid: String) {
        if favoriteAppUUIDs.contains(uuid) {
            favoriteAppUUIDs.remove(uuid)
        } else {
            favoriteAppUUIDs.insert(uuid)
        }
    }

    func isAutoUpdateAllowed(for uuid: String) -> Bool {
        if matchingMode == .favoritesOnly, !favoriteAppUUIDs.contains(uuid) {
            return false
        }
        return !autoUpdateAllowlistActive || autoUpdateAppUUIDs.contains(uuid)
    }

    /// Makes the first per-app opt-out meaningful even while the default is
    /// "all eligible apps": materialize every other eligible library UUID as
    /// the allowlist, then continue toggling explicit membership.
    func toggleAutoUpdate(for uuid: String) {
        var allUUIDs = Set(Storage.shared.getSignedApps().compactMap(\.uuid))
        allUUIDs.formUnion(Storage.shared.getImportedApps().compactMap(\.uuid))
        allUUIDs.insert(uuid)
        toggleAutoUpdate(for: uuid, allUUIDs: allUUIDs)
    }

    func toggleAutoUpdate(for uuid: String, allUUIDs: Set<String>) {
        if !autoUpdateAllowlistActive {
            autoUpdateAllowlistActive = true
            autoUpdateAppUUIDs = Set(allUUIDs.filter { candidate in
                candidate != uuid && (matchingMode != .favoritesOnly || favoriteAppUUIDs.contains(candidate))
            })
            return
        }
        if autoUpdateAppUUIDs.contains(uuid) {
            autoUpdateAppUUIDs.remove(uuid)
        } else if matchingMode != .favoritesOnly || favoriteAppUUIDs.contains(uuid) {
            autoUpdateAppUUIDs.insert(uuid)
        }
    }

    func resetToDefaults() {
        nameMatchingMode = .balanced
        sameDeveloper = false
        samePlaceItCameFrom = false
        includeBetas = false
        includeNoDownload = false
        matchingMode = .updateMatching
        autoUpdateCertificate = "Global Default"
        autoUpdateAppUUIDs = []
        autoUpdateAllowlistActive = false
        objectWillChange.send()
    }
}
