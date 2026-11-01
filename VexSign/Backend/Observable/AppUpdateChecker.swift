//
//  AppUpdateChecker.swift
//  VexSign — Configurable update tracking with name matching, developer filters, and beta exclusion.
//

import SwiftUI
import Combine
import AltSourceKit
import NimbleViews
import UIKit
import CoreData
import OSLog

// MARK: - Shared Update Checker
final class AppUpdateChecker: ObservableObject {
    static let shared = AppUpdateChecker()
    
    @Published private(set) var appsWithUpdates: Set<String> = []
    @Published private(set) var updateCount: Int = 0
    @Published private(set) var availableUpdates: [SourcedUpdate] = []
    
    private var updateCache: [String: Bool] = [:]
    private let cacheQueue = DispatchQueue(label: "com.vexsign.updatechecker", attributes: .concurrent)
    
    private init() {}
    
    func checkForUpdates(
        app: ASRepository.App,
        signedApps: FetchedResults<Signed>,
        importedApps: FetchedResults<Imported>
    ) -> Bool {
        let cacheKey = app.currentUniqueId
        return cacheQueue.sync(execute: { updateCache[cacheKey] }) ?? false
    }

    func precomputeAllUpdates(
        sources: [ASRepository],
        signedApps: FetchedResults<Signed>,
        importedApps: FetchedResults<Imported>
    ) async {
        await Task.detached(priority: .userInitiated) {
            var newCache: [String: Bool] = [:]
            var updatesSet = Set<String>()
            var uniqueApps = Set<String>()
            var sourcedList: [SourcedUpdate] = []

            let ignored = SkippedUpdatesManager.persisted
            let perAppRules = PerAppUpdateRulesStore.persisted

            for source in sources {
                for app in source.apps {
                    var hasUpdate = self.computeUpdate(
                        app: app,
                        source: source,
                        signedApps: signedApps,
                        importedApps: importedApps
                    ) && !ignored.contains(app.id ?? "")

                    // Per-app update rules: disable updates, ignore a specific
                    // version, or ignore this source for this bundle id.
                    if hasUpdate, let bundleID = app.id {
                        let rule = perAppRules[bundleID] ?? PerAppUpdateRule()
                        if rule.disableUpdates {
                            hasUpdate = false
                        }
                        if let ignoredVersion = rule.ignoredVersion, !ignoredVersion.isEmpty,
                           let sourceVersion = app.currentVersion,
                           sourceVersion.compare(ignoredVersion, options: .caseInsensitive) == .orderedSame {
                            hasUpdate = false
                        }
                        if let ignoredSource = rule.ignoredSourceID, !ignoredSource.isEmpty,
                           let sourceID = source.id, sourceID == ignoredSource {
                            hasUpdate = false
                        }
                    }

                    newCache[app.currentUniqueId] = hasUpdate

                    if hasUpdate {
                        updatesSet.insert(app.currentUniqueId)
                        if let installedApp = self.findInstalledApp(
                            for: app,
                            source: source,
                            signedApps: signedApps,
                            importedApps: importedApps
                        ) {
                            uniqueApps.insert(installedApp.uuid)
                            sourcedList.append(SourcedUpdate(
                                id: app.currentUniqueId,
                                app: app,
                                sourceName: source.name ?? "",
                                installedVersion: installedApp.version,
                                sourceVersion: app.currentVersion,
                                installedAppUUID: installedApp.uuid,
                                installedAppName: installedApp.name,
                                installedAppIdentifier: installedApp.identifier,
                                sourceURL: source.sourceURL
                            ))
                        }
                    }
                }
            }

            // Preferred-source resolution: when an app has a preferred
            // repository rule, keep only the update from that source (if it
            // published one); duplicates from other sources are dropped.
            if !sourcedList.isEmpty {
                var byInstalledApp: [String: [Int]] = [:]
                for (index, update) in sourcedList.enumerated() {
                    // UUID is preferred; the bundle identifier groups updates
                    // for apps whose UUID is unavailable. The empty-string
                    // group is harmless: the dedupe below only drops entries
                    // that have a resolvable bundle ID and a preferred source.
                    let key = update.installedAppUUID ?? update.installedAppIdentifier ?? ""
                    byInstalledApp[key, default: []].append(index)
                }
                var dropIndices = Set<Int>()
                for (_, indices) in byInstalledApp where indices.count > 1 {
                    guard let bundleID = sourcedList[indices[0]].installedAppIdentifier,
                          let preferred = PerAppUpdateRulesStore.preferredSourceID(forBundleID: bundleID) else { continue }
                    // The update entries don't carry source identifiers, only
                    // names/URLs; match by name against the preferred source.
                    let preferredName = sources.first { $0.id == preferred }?.name
                    let keep = indices.first { sourcedList[$0].sourceName == (preferredName ?? "") } ?? indices[0]
                    for index in indices where index != keep {
                        dropIndices.insert(index)
                    }
                }
                if !dropIndices.isEmpty {
                    sourcedList = sourcedList.enumerated()
                        .filter { !dropIndices.contains($0.offset) }
                        .map { $0.element }
                }
            }
            
            let finalUpdatesSet = updatesSet
            let finalUpdateCount = uniqueApps.count
            let finalSourcedList = sourcedList

            await MainActor.run {
                self.cacheQueue.async(flags: .barrier) {
                    self.updateCache = newCache
                }
                self.appsWithUpdates = finalUpdatesSet
                self.updateCount = finalUpdateCount
                self.availableUpdates = finalSourcedList
                WidgetStatusPublisher.publish()
            }
        }.value
    }

    private func computeUpdate(
        app: ASRepository.App,
        source: ASRepository? = nil,
        signedApps: FetchedResults<Signed>,
        importedApps: FetchedResults<Imported>
    ) -> Bool {
        let prefs = UpdateMatchingPreferences.shared

        // 1. Download link requirement
        if !prefs.includeNoDownload && app.currentDownloadUrl == nil {
            return false
        }

        // 2. Beta release filter
        if !prefs.includeBetas {
            let ver = (app.currentVersion ?? "").lowercased()
            let title = app.currentName.lowercased()
            let isBeta = ver.contains("beta") || ver.contains("alpha") || ver.contains("rc") || ver.contains("nightly") || title.contains("beta")
            if isBeta {
                return false
            }
        }

        guard let installed = findInstalledApp(
            for: app,
            source: source,
            signedApps: signedApps,
            importedApps: importedApps
        ) else {
            return false
        }

        // 3. Narrow: Same place it came from
        if prefs.samePlaceItCameFrom, let repoUrl = source?.sourceURL, let appSourceUrl = installed.sourceURL {
            let repoHost = repoUrl.host?.lowercased() ?? repoUrl.absoluteString.lowercased()
            let appHost = appSourceUrl.host?.lowercased() ?? appSourceUrl.absoluteString.lowercased()
            if !repoHost.isEmpty && !appHost.isEmpty && repoHost != appHost {
                return false
            }
        }

        // 4. Narrow: Same developer
        if prefs.sameDeveloper, let dev = app.developer, !dev.isEmpty {
            let devLower = dev.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if let installedId = installed.identifier {
                let parts = installedId.split(separator: ".")
                if parts.count >= 2 {
                    let devPart = String(parts[1]).lowercased()
                    let devSanitized = devLower.replacingOccurrences(of: " ", with: "")
                    if !devSanitized.contains(devPart) && !devPart.contains(devSanitized) && !devLower.contains(devPart) {
                        // Not matching developer token
                        return false
                    }
                }
            }
        }
        
        return hasUpdate(
            installedVersion: installed.version,
            sourceVersion: app.currentVersion
        )
    }
    
    func clearCache() {
        cacheQueue.async(flags: .barrier) { [weak self] in
            self?.updateCache.removeAll()
        }
    }
    
    func findInstalledApp(
        for app: ASRepository.App,
        source: ASRepository? = nil,
        signedApps: FetchedResults<Signed>,
        importedApps: FetchedResults<Imported>
    ) -> (version: String?, uuid: String, name: String?, identifier: String?, sourceURL: URL?)? {
        let prefs = UpdateMatchingPreferences.shared
        let appBundleId = app.id ?? ""
        let appNameLower = app.currentName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !appBundleId.isEmpty || !appNameLower.isEmpty else { return nil }

        func identifiersMatch(_ sourceId: String, _ storedId: String?, _ originalId: String?) -> Bool {
            if let originalId = originalId, sourceId == originalId { return true }
            if let storedId = storedId, sourceId == storedId { return true }
            return false
        }

        func normalizeName(_ name: String) -> String {
            var n = name.lowercased()
            let removals = ["++", "pro", "plus", "mod", "premium", "tweaked", "crack", "hack", "beta", "vip"]
            for r in removals {
                n = n.replacingOccurrences(of: r, with: "")
            }
            let allowed = CharacterSet.alphanumerics
            return String(n.unicodeScalars.filter { allowed.contains($0) })
        }

        func namesMatch(_ storedName: String?) -> Bool {
            guard let storedName = storedName, !storedName.isEmpty else { return false }
            let sLower = storedName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

            switch prefs.nameMatchingMode {
            case .off:
                return false
            case .exact:
                return sLower == appNameLower
            case .balanced:
                if sLower == appNameLower { return true }
                let normSource = normalizeName(appNameLower)
                let normStored = normalizeName(sLower)
                return !normSource.isEmpty && normSource == normStored
            case .loose:
                if sLower == appNameLower { return true }
                let normSource = normalizeName(appNameLower)
                let normStored = normalizeName(sLower)
                return (!normSource.isEmpty && !normStored.isEmpty) &&
                       (normSource.contains(normStored) || normStored.contains(normSource))
            }
        }
        
        var allMatchingVersions: [String] = []
        var matchingUUID: String = ""
        var matchingName: String?
        var matchingIdentifier: String?
        var matchingSourceURL: URL?

        for s in signedApps {
            guard !isStrictlyHidden(s.uuid) else { continue }
            let identifierMatch = !appBundleId.isEmpty &&
                identifiersMatch(appBundleId, s.identifier, s.originalIdentifier)
            let nameMatch = namesMatch(s.name)
            
            if identifierMatch || nameMatch {
                if let version = s.version {
                    allMatchingVersions.append(version)
                }
                if matchingUUID.isEmpty {
                    matchingUUID = s.uuid ?? ""
                    matchingName = s.name
                    matchingIdentifier = s.identifier ?? s.originalIdentifier
                    matchingSourceURL = s.source
                }
            }
        }
        
        for i in importedApps {
            guard !isStrictlyHidden(i.uuid) else { continue }
            let identifierMatch = !appBundleId.isEmpty &&
                identifiersMatch(appBundleId, i.identifier, i.originalIdentifier)
            let nameMatch = namesMatch(i.name)
            
            if identifierMatch || nameMatch {
                if let version = i.version {
                    allMatchingVersions.append(version)
                }
                if matchingUUID.isEmpty {
                    matchingUUID = i.uuid ?? ""
                    matchingName = i.name
                    matchingIdentifier = i.identifier ?? i.originalIdentifier
                    matchingSourceURL = i.source
                }
            }
        }
        
        guard !allMatchingVersions.isEmpty else { return nil }

        let highestVersion = allMatchingVersions.max { v1, v2 in
            return !isNewerVersion(v1, than: v2)
        }
        
        return (highestVersion, matchingUUID, matchingName, matchingIdentifier, matchingSourceURL)
    }
    
    /// Strict hiding must also apply to background/update matching. This helper
    /// intentionally reads the persisted privacy state directly because update
    /// precomputation runs off the main actor.
    private func isStrictlyHidden(_ uuid: String?) -> Bool {
        guard let uuid, !uuid.isEmpty,
              UserDefaults.standard.bool(forKey: "VexSign.security.strictHiding") else {
            return false
        }
        let hidden = Set(UserDefaults.standard.stringArray(forKey: "VexSign.security.hiddenAppUUIDs") ?? [])
        return hidden.contains(uuid)
    }

    /// Detailed pending-update rows for the Updates screen and Update All
    func pendingUpdates(
        sources: [ASRepository],
        signedApps: FetchedResults<Signed>,
        importedApps: FetchedResults<Imported>
    ) -> [SourcedUpdate] {
        var rows: [SourcedUpdate] = []
        let ignored = SkippedUpdatesManager.persisted

        for source in sources {
            for app in source.apps {
                let uniqueId = app.currentUniqueId
                guard !ignored.contains(app.id ?? ""), appsWithUpdates.contains(uniqueId) else { continue }

                guard let installed = findInstalledApp(
                    for: app,
                    source: source,
                    signedApps: signedApps,
                    importedApps: importedApps
                ) else { continue }

                rows.append(SourcedUpdate(
                    id: uniqueId,
                    app: app,
                    sourceName: source.name ?? "",
                    installedVersion: installed.version,
                    sourceVersion: app.currentVersion,
                    installedAppUUID: installed.uuid,
                    installedAppName: installed.name,
                    installedAppIdentifier: installed.identifier,
                    sourceURL: source.sourceURL
                ))
            }
        }

        return rows
    }

    func installedAppForUpdate(
        app: ASRepository.App,
        signedApps: FetchedResults<Signed>,
        importedApps: FetchedResults<Imported>
    ) -> AppInfoPresentable? {
        guard let match = findInstalledApp(for: app, signedApps: signedApps, importedApps: importedApps) else {
            return nil
        }

        let uuid = match.uuid
        let signed = signedApps.first { $0.uuid == uuid }
        if let signed { return signed }
        let imported = importedApps.first { $0.uuid == uuid }
        if let imported { return imported }
        return nil
    }

    func hasUpdate(for app: AppInfoPresentable) -> SourcedUpdate? {
        guard let uuid = app.uuid else { return nil }
        return availableUpdates.first { $0.installedAppUUID == uuid }
    }

    func hasUpdate(installedVersion: String?, sourceVersion: String?) -> Bool {
        guard let currentVersion = installedVersion,
              let newVersion = sourceVersion else { return false }
        
        return isNewerVersion(newVersion, than: currentVersion)
    }
    
    private func isNewerVersion(_ new: String, than old: String) -> Bool {
        let newComponents = new.split(separator: ".").compactMap { Int($0) }
        let oldComponents = old.split(separator: ".").compactMap { Int($0) }
        
        let maxCount = max(newComponents.count, oldComponents.count)
        
        for i in 0..<maxCount {
            let newValue = i < newComponents.count ? newComponents[i] : 0
            let oldValue = i < oldComponents.count ? oldComponents[i] : 0
            
            if newValue > oldValue {
                return true
            } else if newValue < oldValue {
                return false
            }
        }
        
        return false
    }
    
    func refreshUpdateCount(
        sources: [ASRepository],
        signedApps: FetchedResults<Signed>,
        importedApps: FetchedResults<Imported>
    ) {
        Task {
            await performUpdateCheck(sources: sources, signedApps: signedApps, importedApps: importedApps)
        }
    }

    /// `@MainActor` because the three `Storage` reads below are view-context
    /// fetches, and a nonisolated async function runs on the generic executor.
    @MainActor
    func checkNow() async {
        let sources = Storage.shared.getSources()
        await SourcesViewModel.shared.fetchSources(sources, refresh: true)
        let repos = Array(SourcesViewModel.shared.sources.values)
        let signed = Storage.shared.getSignedApps()
        let imported = Storage.shared.getImportedApps()
        await precomputeAllUpdates(sources: repos, signedApps: signed, importedApps: imported)
    }
    
    @MainActor
    private func performUpdateCheck(
        sources: [ASRepository],
        signedApps: FetchedResults<Signed>,
        importedApps: FetchedResults<Imported>
    ) async {
        var updatesSet = Set<String>()
        var uniqueApps = Set<String>()
        var sourcedList: [SourcedUpdate] = []

        let ignored = SkippedUpdatesManager.shared.bundleIDs

        for source in sources {
            for app in source.apps {
                if checkForUpdates(
                    app: app,
                    signedApps: signedApps,
                    importedApps: importedApps
                ), !ignored.contains(app.id ?? "") {
                    updatesSet.insert(app.currentUniqueId)

                    if let installedApp = findInstalledApp(
                        for: app,
                        source: source,
                        signedApps: signedApps,
                        importedApps: importedApps
                    ) {
                        uniqueApps.insert(installedApp.uuid)
                        sourcedList.append(SourcedUpdate(
                            id: app.currentUniqueId,
                            app: app,
                            sourceName: source.name ?? "",
                            installedVersion: installedApp.version,
                            sourceVersion: app.currentVersion,
                            installedAppUUID: installedApp.uuid,
                            installedAppName: installedApp.name,
                            installedAppIdentifier: installedApp.identifier,
                            sourceURL: source.sourceURL
                        ))
                    }
                }
            }
        }
        
        self.appsWithUpdates = updatesSet
        self.updateCount = uniqueApps.count
        self.availableUpdates = sourcedList
    }

    // MARK: - Detailed update rows

    struct SourcedUpdate: Identifiable {
        let id: String
        let app: ASRepository.App
        let sourceName: String
        let installedVersion: String?
        let sourceVersion: String?
        var installedAppUUID: String?
        var installedAppName: String?
        var installedAppIdentifier: String?
        var sourceURL: URL?

        var displayName: String { app.currentName }
        var downloadURL: URL? { app.currentDownloadUrl }
        var iconURL: URL? { app.iconURL }
    }
}
