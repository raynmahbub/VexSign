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

    // Only immutable values cross into the update worker; never FetchedResults or NSManagedObject.
    struct InstalledSnapshot: Sendable {
        let version: String?
        let uuid: String?
        let name: String?
        let identifier: String?
        let originalIdentifier: String?
        let source: URL?
    }

    /// Built once per catalog pass. Exact identity lookups do not scan the library.
    struct InstalledIndex {
        let all: [InstalledSnapshot]
        let byIdentifier: [String: [Int]]

        init(signed: [InstalledSnapshot], imported: [InstalledSnapshot]) {
            all = signed + imported
            var index: [String: [Int]] = [:]
            for (offset, app) in all.enumerated() {
                for id in Set([app.identifier, app.originalIdentifier].compactMap { $0 }).filter({ !$0.isEmpty }) {
                    index[id, default: []].append(offset)
                }
            }
            byIdentifier = index
        }

        func exact(_ identifier: String) -> [InstalledSnapshot] {
            (byIdentifier[identifier] ?? []).map { all[$0] }
        }
    }

    struct MatchingSnapshot: Sendable {
        let includeNoDownload: Bool
        let includeBetas: Bool
        let samePlaceItCameFrom: Bool
        let sameDeveloper: Bool
        let nameMatchingMode: NameMatchingMode

        init(includeNoDownload: Bool, includeBetas: Bool = false,
             samePlaceItCameFrom: Bool = false, sameDeveloper: Bool = false,
             nameMatchingMode: NameMatchingMode = .off) {
            self.includeNoDownload = includeNoDownload
            self.includeBetas = includeBetas
            self.samePlaceItCameFrom = samePlaceItCameFrom
            self.sameDeveloper = sameDeveloper
            self.nameMatchingMode = nameMatchingMode
        }

        @MainActor init() {
            let prefs = UpdateMatchingPreferences.shared
            includeNoDownload = prefs.includeNoDownload
            includeBetas = prefs.includeBetas
            samePlaceItCameFrom = prefs.samePlaceItCameFrom
            sameDeveloper = prefs.sameDeveloper
            nameMatchingMode = prefs.nameMatchingMode
        }
    }

    @MainActor private var updateGeneration = UUID()
    @MainActor private var updateWorker: Task<Void, Never>?

    @MainActor
    private func snapshots(signed: FetchedResults<Signed>, imported: FetchedResults<Imported>) -> ([InstalledSnapshot], [InstalledSnapshot]) {
        let signedValues = signed.filter { !isStrictlyHidden($0.uuid) }.map {
            InstalledSnapshot(version: $0.version, uuid: $0.uuid, name: $0.name,
                              identifier: $0.identifier, originalIdentifier: $0.originalIdentifier, source: $0.source)
        }
        let importedValues = imported.filter { !isStrictlyHidden($0.uuid) }.map {
            InstalledSnapshot(version: $0.version, uuid: $0.uuid, name: $0.name,
                              identifier: $0.identifier, originalIdentifier: $0.originalIdentifier, source: $0.source)
        }
        return (signedValues, importedValues)
    }

    private init() {}

    func checkForUpdates(
        app: ASRepository.App,
        signedApps: FetchedResults<Signed>,
        importedApps: FetchedResults<Imported>
    ) -> Bool {
        let cacheKey = app.currentUniqueId
        return cacheQueue.sync(execute: { updateCache[cacheKey] }) ?? false
    }

    @MainActor
    func precomputeAllUpdates(
        sources: [ASRepository],
        signedApps: FetchedResults<Signed>,
        importedApps: FetchedResults<Imported>
    ) async {
        let (signedValues, importedValues) = snapshots(signed: signedApps, imported: importedApps)
        let preferences = MatchingSnapshot()
        let ignored = SkippedUpdatesManager.persisted
        let perAppRules = PerAppUpdateRulesStore.persisted
        let generation = UUID()
        updateWorker?.cancel()
        updateGeneration = generation
        let worker = Task.detached(priority: .userInitiated) {
            let installedIndex = InstalledIndex(signed: signedValues, imported: importedValues)
            var newCache: [String: Bool] = [:]
            var sourcedList: [SourcedUpdate] = []

            for source in sources {
                guard !Task.isCancelled else { return }
                for app in source.apps {
                    guard !Task.isCancelled else { return }
                    var hasUpdate = self.computeUpdate(
                        app: app,
                        source: source,
                        signedApps: signedValues,
                        importedApps: importedValues,
                        prefs: preferences, index: installedIndex
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
                        if let installedApp = self.findInstalledApp(
                            for: app,
                            source: source,
                            signedApps: signedValues,
                            importedApps: importedValues,
                            prefs: preferences, index: installedIndex
                        ) {
                            sourcedList.append(SourcedUpdate(
                                id: app.currentUniqueId,
                                app: app,
                                sourceName: source.name ?? "",
                                installedVersion: installedApp.version,
                                sourceVersion: app.currentVersion,
                                installedAppUUID: installedApp.uuid,
                                installedAppName: installedApp.name,
                                installedAppIdentifier: installedApp.identifier,
                                sourceURL: source.sourceURL,
                                sourceID: source.id
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
                          let preferred = perAppRules[bundleID]?.preferredSourceID else { continue }
                    // IDs, not display names: unrelated repositories can share the same name.
                    let keep = indices.first { sourcedList[$0].sourceID == preferred }
                    for index in indices where index != keep { dropIndices.insert(index) }
                }
                if !dropIndices.isEmpty {
                    sourcedList = sourcedList.enumerated()
                        .filter { !dropIndices.contains($0.offset) }
                        .map { $0.element }
                }
            }

            let finalUpdatesSet = Set(sourcedList.map(\.id))
            for key in newCache.keys { newCache[key] = finalUpdatesSet.contains(key) }
            let finalUpdateCount = Set(sourcedList.compactMap(\.installedAppUUID)).count
            let finalSourcedList = sourcedList
            let finalCache = newCache

            await MainActor.run {
                guard !Task.isCancelled, self.updateGeneration == generation else { return }
                self.cacheQueue.sync(flags: .barrier) {
                    self.updateCache = finalCache
                }
                self.appsWithUpdates = finalUpdatesSet
                self.updateCount = finalUpdateCount
                self.availableUpdates = finalSourcedList
                WidgetStatusPublisher.publish()
            }
        }
        updateWorker = worker
        await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        if updateGeneration == generation { updateWorker = nil }
    }

    private func computeUpdate(
        app: ASRepository.App,
        source: ASRepository? = nil,
        signedApps: [InstalledSnapshot],
        importedApps: [InstalledSnapshot],
        prefs: MatchingSnapshot,
        index: InstalledIndex? = nil
    ) -> Bool {

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
            importedApps: importedApps,
            prefs: prefs, index: index
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

    @MainActor
    func clearCache() {
        updateWorker?.cancel()
        updateWorker = nil
        updateGeneration = UUID()
        appsWithUpdates = []
        updateCount = 0
        availableUpdates = []
        cacheQueue.sync(flags: .barrier) {
            updateCache.removeAll()
        }
    }

    @MainActor
    func findInstalledApp(
        for app: ASRepository.App,
        source: ASRepository? = nil,
        signedApps: FetchedResults<Signed>,
        importedApps: FetchedResults<Imported>
    ) -> (version: String?, uuid: String, name: String?, identifier: String?, sourceURL: URL?)? {
        let (signedValues, importedValues) = snapshots(signed: signedApps, imported: importedApps)
        return findInstalledApp(for: app, source: source, signedApps: signedValues,
                                importedApps: importedValues, prefs: MatchingSnapshot())
    }

    func findInstalledApp(
        for app: ASRepository.App,
        source: ASRepository? = nil,
        signedApps: [InstalledSnapshot],
        importedApps: [InstalledSnapshot],
        prefs: MatchingSnapshot,
        index: InstalledIndex? = nil
    ) -> (version: String?, uuid: String, name: String?, identifier: String?, sourceURL: URL?)? {
        let appBundleId = app.id ?? ""
        let appNameLower = app.currentName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        guard !appBundleId.isEmpty || !appNameLower.isEmpty else { return nil }

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

        let lookup = index ?? InstalledIndex(signed: signedApps, imported: importedApps)
        let exact = lookup.exact(appBundleId)
        // Exact identity always wins over name similarity. Name fallback is only for manual opt-in.
        let candidates = exact.isEmpty ? lookup.all.filter { namesMatch($0.name) } : exact
        guard !candidates.isEmpty else { return nil }
        // Different installed identities must never be silently combined into one update target.
        let identities = Set(candidates.map { $0.identifier ?? $0.originalIdentifier ?? $0.uuid ?? "" })
        guard identities.count == 1, identities.first != "" else { return nil }
        let versioned = candidates.filter { $0.version != nil && !($0.uuid ?? "").isEmpty }
        let selected = versioned.sorted { lhs, rhs in
            if Self.isNewerVersion(lhs.version ?? "", than: rhs.version ?? "") { return true }
            if Self.isNewerVersion(rhs.version ?? "", than: lhs.version ?? "") { return false }
            return (lhs.uuid ?? "") < (rhs.uuid ?? "")
        }.first
        guard let selected, let uuid = selected.uuid else { return nil }
        return (selected.version, uuid, selected.name, selected.identifier ?? selected.originalIdentifier, selected.source)
    }

    /// Privacy filtering is performed before values leave the view-context queue.
    private func isStrictlyHidden(_ uuid: String?) -> Bool {
        guard let uuid, !uuid.isEmpty,
              UserDefaults.standard.bool(forKey: "VexSign.security.strictHiding") else {
            return false
        }
        let hidden = Set(UserDefaults.standard.stringArray(forKey: "VexSign.security.hiddenAppUUIDs") ?? [])
        return hidden.contains(uuid)
    }

    /// Detailed pending-update rows for the Updates screen and Update All
    @MainActor
    func pendingUpdates(
        sources: [ASRepository],
        signedApps: FetchedResults<Signed>,
        importedApps: FetchedResults<Imported>
    ) -> [SourcedUpdate] {
        let ignored = SkippedUpdatesManager.persisted
        let visibleIDs = Set(signedApps.filter { !isStrictlyHidden($0.uuid) }.compactMap(\.uuid)
                             + importedApps.filter { !isStrictlyHidden($0.uuid) }.compactMap(\.uuid))
        let sourceIDs = Set(sources.compactMap(\.id))
        let sourceURLs = Set(sources.compactMap(\.sourceURL))
        return availableUpdates.filter { update in
            guard let uuid = update.installedAppUUID, visibleIDs.contains(uuid),
                  !ignored.contains(update.app.id ?? "") else { return false }
            if let id = update.sourceID { return sourceIDs.contains(id) }
            return update.sourceURL.map { sourceURLs.contains($0) } ?? false
        }
    }

    @MainActor
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

        return Self.isNewerVersion(newVersion, than: currentVersion)
    }

    /// Compares dotted numeric versions with optional `v` prefixes and SemVer
    /// prerelease/build metadata. Invalid version strings fail closed instead of
    /// silently dropping nonnumeric components and manufacturing an ordering.
    private static func isNewerVersion(_ new: String, than old: String) -> Bool {
        guard let newer = ParsedVersion(new), let older = ParsedVersion(old) else { return false }
        return newer.isNewer(than: older)
    }

    private struct ParsedVersion {
        let core: [String]
        let prerelease: [String]?

        init?(_ rawValue: String) {
            var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.count > 1, let first = value.first, first == "v" || first == "V",
               value.dropFirst().first?.isNumber == true {
                value.removeFirst()
            }

            // Build metadata does not affect SemVer precedence.
            value = String(value.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)[0])
            let pieces = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            guard let coreText = pieces.first, !coreText.isEmpty else { return nil }
            let core = coreText.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard !core.isEmpty, core.allSatisfy({ Self.isASCIIDigits($0) }) else { return nil }

            if pieces.count == 2 {
                let prereleaseText = String(pieces[1])
                let identifiers = prereleaseText.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
                guard !identifiers.isEmpty, identifiers.allSatisfy({ identifier in
                    !identifier.isEmpty && identifier.unicodeScalars.allSatisfy {
                        (48...57).contains(Int($0.value)) || (65...90).contains(Int($0.value))
                            || (97...122).contains(Int($0.value)) || $0 == "-"
                    }
                }) else { return nil }
                self.prerelease = identifiers
            } else {
                self.prerelease = nil
            }
            self.core = core
        }

        func isNewer(than other: ParsedVersion) -> Bool {
            for index in 0..<max(core.count, other.core.count) {
                let left = index < core.count ? core[index] : "0"
                let right = index < other.core.count ? other.core[index] : "0"
                let order = Self.compareNumeric(left, right)
                if order != .orderedSame { return order == .orderedDescending }
            }

            switch (prerelease, other.prerelease) {
            case (nil, nil):
                return false
            case (nil, .some):
                return true // A release outranks its prereleases.
            case (.some, nil):
                return false
            case let (.some(left), .some(right)):
                for index in 0..<max(left.count, right.count) {
                    guard index < left.count else { return false }
                    guard index < right.count else { return true }
                    // SemVer prerelease identifiers are case-sensitive ASCII.
                    let lhs = left[index]
                    let rhs = right[index]
                    let lhsNumeric = Self.isASCIIDigits(lhs)
                    let rhsNumeric = Self.isASCIIDigits(rhs)
                    let order: ComparisonResult
                    if lhsNumeric && rhsNumeric {
                        order = Self.compareNumeric(lhs, rhs)
                    } else if lhsNumeric != rhsNumeric {
                        order = lhsNumeric ? .orderedAscending : .orderedDescending
                    } else {
                        order = lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
                    }
                    if order != .orderedSame { return order == .orderedDescending }
                }
                return false
            }
        }

        private static func isASCIIDigits(_ value: String) -> Bool {
            !value.isEmpty && value.unicodeScalars.allSatisfy { (48...57).contains(Int($0.value)) }
        }

        private static func compareNumeric(_ lhs: String, _ rhs: String) -> ComparisonResult {
            let left = String(lhs.drop(while: { $0 == "0" }))
            let right = String(rhs.drop(while: { $0 == "0" }))
            let normalizedLeft = left.isEmpty ? "0" : left
            let normalizedRight = right.isEmpty ? "0" : right
            if normalizedLeft.count != normalizedRight.count {
                return normalizedLeft.count < normalizedRight.count ? .orderedAscending : .orderedDescending
            }
            if normalizedLeft == normalizedRight { return .orderedSame }
            return normalizedLeft < normalizedRight ? .orderedAscending : .orderedDescending
        }
    }

    @MainActor
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
    /// Cached catalogs are useful only while their source remains configured. The
    /// view model can retain last-known-good data, so callers must scope it to the
    /// persisted source list before calculating or offering updates.
    static func configuredRepositories(in cached: [ASRepository], sourceURLs: Set<URL>) -> [ASRepository] {
        cached.filter { repository in
            guard let sourceURL = repository.sourceURL else { return false }
            return sourceURLs.contains(sourceURL)
        }
    }

    @MainActor
    func checkNow() async {
        let sources = Storage.shared.getSources()
        let sourceURLs = Set(sources.compactMap(\.sourceURL))
        await SourcesViewModel.shared.fetchSources(sources, refresh: true)
        let cached = Array(SourcesViewModel.shared.sources.values)
        let repositories = Self.configuredRepositories(in: cached, sourceURLs: sourceURLs)
        let signed = Storage.shared.getSignedApps()
        let imported = Storage.shared.getImportedApps()
        await precomputeAllUpdates(sources: repositories, signedApps: signed, importedApps: imported)
    }

    @MainActor
    private func performUpdateCheck(
        sources: [ASRepository],
        signedApps: FetchedResults<Signed>,
        importedApps: FetchedResults<Imported>
    ) async {
        await precomputeAllUpdates(sources: sources, signedApps: signedApps, importedApps: importedApps)
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
        var sourceID: String? = nil

        var displayName: String { app.currentName }
        var downloadURL: URL? { app.currentDownloadUrl }
        var iconURL: URL? { app.iconURL }
    }
}
