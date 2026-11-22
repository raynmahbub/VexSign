//
//  SourceAppsCoordinator+Data.swift
//  VexSign
//
//  Extracted from SourceAppsTableRepresentableView.swift for maintainability.
//

import SwiftUI
import AltSourceKit

extension SourceAppsTableRepresentableView.Coordinator {
        // MARK: - Off-Main Snapshot Builder (Data-Race-Free)

        struct BuildSnapshotInput {
            let sources: [ASRepository]
            let cachedBase: (
                allApps: [(source: ASRepository, app: ASRepository.App)],
                searchableApps: [(app: (source: ASRepository, app: ASRepository.App), searchString: String)]
            )?
            let searchText: String
            let sortOption: SourceAppsView.SortOption
            let sortAscending: Bool
            let showUpdatesOnly: Bool
            let appsWithUpdates: Set<String>
            let hideDuplicates: Bool
        }

        struct BuildSnapshotOutput {
            let allApps: [(source: ASRepository, app: ASRepository.App)]
            let searchableApps: [(app: (source: ASRepository, app: ASRepository.App), searchString: String)]
            let sortedApps: [(source: ASRepository, app: ASRepository.App)]
            let groupedByName: [String: [(source: ASRepository, app: ASRepository.App)]]
            let groupedByDate: [String: [(source: ASRepository, app: ASRepository.App)]]
            let sectionTitles: [String]
        }

        static func computeSnapshot(_ input: BuildSnapshotInput) -> BuildSnapshotOutput {
            let allApps: [(source: ASRepository, app: ASRepository.App)]
            let searchableApps: [(app: (source: ASRepository, app: ASRepository.App), searchString: String)]

            if let cachedBase = input.cachedBase {
                allApps = cachedBase.allApps
                searchableApps = cachedBase.searchableApps
            } else {
                let builtAll = input.sources.flatMap { source in
                    source.apps.map { (source: source, app: $0) }
                }
                let builtSearchable = builtAll.map { entry in
                    let searchComponents = [
                        entry.app.name,
                        entry.app.description,
                        entry.app.subtitle,
                        entry.app.localizedDescription,
                        entry.app.id
                    ].compactMap { $0?.lowercased() }
                    return (app: entry, searchString: searchComponents.joined(separator: " "))
                }
                allApps = builtAll
                searchableApps = builtSearchable
            }

            let lowercaseSearch = input.searchText.lowercased()
            let filtered: [(source: ASRepository, app: ASRepository.App)]
            if lowercaseSearch.isEmpty {
                filtered = allApps
            } else {
                filtered = searchableApps.compactMap { searchableApp in
                    searchableApp.searchString.contains(lowercaseSearch) ? searchableApp.app : nil
                }
            }

            let updatesFiltered = input.showUpdatesOnly
                ? filtered.filter { input.appsWithUpdates.contains($0.app.currentUniqueId) }
                : filtered

            let deduped: [(source: ASRepository, app: ASRepository.App)]
            if input.hideDuplicates {
                var seen = Set<String>()
                deduped = updatesFiltered.filter { entry in
                    let key = entry.app.id ?? entry.app.currentUniqueId
                    return seen.insert(key).inserted
                }
            } else {
                deduped = updatesFiltered
            }

            switch input.sortOption {
            case .default:
                let sorted = input.sortAscending ? deduped : Array(deduped.reversed())
                return BuildSnapshotOutput(
                    allApps: allApps,
                    searchableApps: searchableApps,
                    sortedApps: sorted,
                    groupedByName: [:],
                    groupedByDate: [:],
                    sectionTitles: []
                )

            case .name:
                let sorted = deduped.sorted { lhs, rhs in
                    let n1 = lhs.app.name ?? ""
                    let n2 = rhs.app.name ?? ""
                    let comparison = n1.localizedCaseInsensitiveCompare(n2) == .orderedAscending
                    return input.sortAscending ? comparison : !comparison
                }
                let groupedByName = Dictionary(grouping: sorted) { entry in
                    let first = entry.app.name?.trimmingCharacters(in: .whitespacesAndNewlines).first?.uppercased() ?? "#"
                    return first.range(of: "[A-Z]", options: .regularExpression) != nil ? first : "#"
                }
                let sectionTitles = groupedByName.keys.sorted { lhs, rhs in
                    if lhs == "#" { return false }
                    if rhs == "#" { return true }
                    return input.sortAscending ? lhs < rhs : lhs > rhs
                }
                return BuildSnapshotOutput(
                    allApps: allApps,
                    searchableApps: searchableApps,
                    sortedApps: sorted,
                    groupedByName: groupedByName,
                    groupedByDate: [:],
                    sectionTitles: sectionTitles
                )

            case .date:
                let formatter = DateFormatter()
                formatter.dateFormat = "MMMM d, yyyy"
                let grouped = Dictionary(grouping: deduped) {
                    $0.app.currentDate?.date.stripTime() ?? .distantPast
                }
                let sortedDates = grouped.keys.sorted(by: { input.sortAscending ? $0 > $1 : $0 < $1 })
                let groupedByDate: [String: [(source: ASRepository, app: ASRepository.App)]] = grouped.reduce(into: [:]) { result, pair in
                    let key = formatter.string(from: pair.key)
                    result[key] = pair.value.sorted { lhs, rhs in
                        let d1 = lhs.app.currentDate?.date ?? .distantPast
                        let d2 = rhs.app.currentDate?.date ?? .distantPast
                        return d1 > d2
                    }
                }
                let sectionTitles = sortedDates.map { formatter.string(from: $0) }
                let sorted = sortedDates.flatMap { date -> [(source: ASRepository, app: ASRepository.App)] in
                    let key = formatter.string(from: date)
                    return groupedByDate[key] ?? []
                }
                return BuildSnapshotOutput(
                    allApps: allApps,
                    searchableApps: searchableApps,
                    sortedApps: sorted,
                    groupedByName: [:],
                    groupedByDate: groupedByDate,
                    sectionTitles: sectionTitles
                )
            }
        }

        // MARK: - Sorting & Filtering (Main-Thread Entry Points)

        func calculateSortedApps() -> [(source: ASRepository, app: ASRepository.App)] {
            let input = BuildSnapshotInput(
                sources: sources,
                cachedBase: cache.allApps.isEmpty ? nil : (cache.allApps, cache.searchableApps),
                searchText: searchText,
                sortOption: sortOption,
                sortAscending: sortAscending,
                showUpdatesOnly: showUpdatesOnly,
                appsWithUpdates: updateChecker.appsWithUpdates,
                hideDuplicates: SourcePreferences.hideDuplicates
            )
            let output = Self.computeSnapshot(input)
            cache.allApps = output.allApps
            cache.searchableApps = output.searchableApps
            cache.groupedByName = output.groupedByName
            cache.groupedByDate = output.groupedByDate
            cache.sectionTitles = output.sectionTitles
            return output.sortedApps
        }
        
        func filterBySearch(_ apps: [(source: ASRepository, app: ASRepository.App)]) -> [(source: ASRepository, app: ASRepository.App)] {
            let lowercaseSearch = searchText.lowercased()
            guard !lowercaseSearch.isEmpty else { return apps }

            return cache.searchableApps.compactMap { searchableApp in
                searchableApp.searchString.contains(lowercaseSearch) ? searchableApp.app : nil
            }
        }
        
        func sortByName(_ apps: [(source: ASRepository, app: ASRepository.App)]) -> [(source: ASRepository, app: ASRepository.App)] {
            let sorted = apps.sorted { lhs, rhs in
                let n1 = lhs.app.name ?? ""
                let n2 = rhs.app.name ?? ""
                let comparison = n1.localizedCaseInsensitiveCompare(n2) == .orderedAscending
                return sortAscending ? comparison : !comparison
            }
            
            cache.groupedByName = Dictionary(grouping: sorted) { entry in
                let first = entry.app.name?.trimmingCharacters(in: .whitespacesAndNewlines).first?.uppercased() ?? "#"
                return first.range(of: "[A-Z]", options: .regularExpression) != nil ? first : "#"
            }
            
            cache.sectionTitles = cache.groupedByName.keys.sorted { lhs, rhs in
                if lhs == "#" { return false }
                if rhs == "#" { return true }
                return sortAscending ? lhs < rhs : lhs > rhs
            }
            
            clearDateGrouping()
            return sorted
        }
        
        func sortByDate(_ apps: [(source: ASRepository, app: ASRepository.App)]) -> [(source: ASRepository, app: ASRepository.App)] {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMMM d, yyyy"

            let grouped = Dictionary(grouping: apps) {
                $0.app.currentDate?.date.stripTime() ?? .distantPast
            }

            let sortedDates = grouped.keys.sorted(by: { sortAscending ? $0 > $1 : $0 < $1 })

            // Within each day, always sort newest-first regardless of sortAscending.
            cache.groupedByDate = grouped.reduce(into: [:]) { result, pair in
                let key = formatter.string(from: pair.key)
                let sortedApps = pair.value.sorted { lhs, rhs in
                    let d1 = lhs.app.currentDate?.date ?? .distantPast
                    let d2 = rhs.app.currentDate?.date ?? .distantPast
                    return d1 > d2
                }
                result[key] = sortedApps
            }

            cache.sectionTitles = sortedDates.map { formatter.string(from: $0) }

            let sorted = sortedDates.flatMap { date -> [(source: ASRepository, app: ASRepository.App)] in
                let key = formatter.string(from: date)
                return cache.groupedByDate[key] ?? []
            }

            clearNameGrouping()
            return sorted
        }
        
        func clearGroupedData() {
            cache.groupedByDate = [:]
            cache.groupedByName = [:]
            cache.sectionTitles = []
        }
        
        func clearNameGrouping() {
            cache.groupedByName = [:]
        }
        
        func clearDateGrouping() {
            cache.groupedByDate = [:]
        }
        
        // MARK: - Index Path Calculation
        
        func calculateIndexPath(for targetIndex: Int, in allApps: [(source: ASRepository, app: ASRepository.App)]) -> IndexPath {
            switch sortOption {
            case .default:
                return IndexPath(row: targetIndex, section: 0)
                
            case .name:
                return calculateNameIndexPath(for: targetIndex, in: allApps)
                
            case .date:
                return calculateDateIndexPath(for: targetIndex, in: allApps)
            }
        }
        
        func calculateNameIndexPath(for targetIndex: Int, in allApps: [(source: ASRepository, app: ASRepository.App)]) -> IndexPath {
            let targetApp = allApps[targetIndex]
            let firstLetter = targetApp.app.name?.trimmingCharacters(in: .whitespacesAndNewlines).first?.uppercased() ?? "#"
            let sectionKey = firstLetter.range(of: "[A-Z]", options: .regularExpression) != nil ? firstLetter : "#"
            
            guard let sectionIndex = cache.sectionTitles.firstIndex(of: sectionKey),
                  let appsInSection = cache.groupedByName[sectionKey],
                  let rowIndex = appsInSection.firstIndex(where: {
                      $0.app.currentUniqueId == targetApp.app.currentUniqueId
                  }) else {
                return IndexPath(row: 0, section: 0)
            }
            
            return IndexPath(row: rowIndex, section: sectionIndex)
        }
        
        func calculateDateIndexPath(for targetIndex: Int, in allApps: [(source: ASRepository, app: ASRepository.App)]) -> IndexPath {
            let targetApp = allApps[targetIndex]
            let formatter = DateFormatter()
            formatter.dateFormat = "MMMM d, yyyy"
            let dateKey = formatter.string(from: targetApp.app.currentDate?.date.stripTime() ?? .distantPast)
            
            guard let sectionIndex = cache.sectionTitles.firstIndex(of: dateKey),
                  let appsInSection = cache.groupedByDate[dateKey],
                  let rowIndex = appsInSection.firstIndex(where: {
                      $0.app.currentUniqueId == targetApp.app.currentUniqueId
                  }) else {
                return IndexPath(row: 0, section: 0)
            }
            
            return IndexPath(row: rowIndex, section: sectionIndex)
        }
        
        // MARK: - Cache Management

        // MARK: - Render Window

        /// Caches rows-per-section and running offset for the current sort, so the window applies across sections in O(1).
        func rebuildSectionMetrics() {
            let counts: [Int]
            switch sortOption {
            case .default:
                counts = [cache.sortedApps.count]
            case .name:
                counts = cache.sectionTitles.map { cache.groupedByName[$0]?.count ?? 0 }
            case .date:
                counts = cache.sectionTitles.map { cache.groupedByDate[$0]?.count ?? 0 }
            }
            cache.sectionRowCounts = counts

            var cumulative = [Int]()
            cumulative.reserveCapacity(counts.count)
            var running = 0
            for c in counts {
                cumulative.append(running)
                running += c
            }
            cache.sectionCumulative = cumulative
        }

        /// Sections currently rendered and rows in the last (possibly partial) one, given `displayLimit`.
        func visibleWindow() -> (sections: Int, lastRows: Int) {
            let counts = cache.sectionRowCounts
            guard !counts.isEmpty else { return (0, 0) }

            var cum = 0
            for (i, c) in counts.enumerated() {
                if cum + c >= displayLimit {
                    let rows = displayLimit - cum
                    return rows > 0 ? (i + 1, min(rows, c)) : (i, 0)
                }
                cum += c
            }
            return (counts.count, counts.last ?? 0)
        }

        func invalidateCache(rebuildBase: Bool = true, resetWindow: Bool = true) {
            buildGeneration &+= 1
            let generation = buildGeneration

            if rebuildBase {
                cache.clearBase()
            }
            cache.clearSorted()
            isBuilding = true

            // Capture value-type inputs on the main thread so the global worker never
            // reads or mutates `self` / `self.cache` concurrently with UIKit callbacks.
            let snapshotInput = BuildSnapshotInput(
                sources: sources,
                cachedBase: (!rebuildBase && !cache.allApps.isEmpty) ? (cache.allApps, cache.searchableApps) : nil,
                searchText: searchText,
                sortOption: sortOption,
                sortAscending: sortAscending,
                showUpdatesOnly: showUpdatesOnly,
                appsWithUpdates: updateChecker.appsWithUpdates,
                hideDuplicates: SourcePreferences.hideDuplicates
            )

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let output = Self.computeSnapshot(snapshotInput)

                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.buildGeneration == generation else { return }

                    self.cache.allApps = output.allApps
                    self.cache.searchableApps = output.searchableApps
                    self.cache.sortedApps = output.sortedApps
                    self.cache.groupedByName = output.groupedByName
                    self.cache.groupedByDate = output.groupedByDate
                    self.cache.sectionTitles = output.sectionTitles
                    self.rebuildSectionMetrics()
                    self.isBuilding = false
                    // Reset the window to top only when the list changed; cosmetic refreshes keep scroll position.
                    if resetWindow {
                        self.displayLimit = self.pageSize
                    } else {
                        // Keep covering the current scroll position.
                        self.displayLimit = min(max(self.displayLimit, self.pageSize), max(output.sortedApps.count, self.pageSize))
                    }
                    self.isGrowingWindow = false

                    if let tableView = self.uiTableView {
                        // tableView may be gone during rapid search — guard against crashes.
                        guard tableView.window != nil else {
                            self.onUIReady?()
                            return
                        }

                        UIView.transition(with: tableView, duration: 0.3, options: [.transitionCrossDissolve], animations: {
                            tableView.reloadData()
                        }) { [weak self] _ in
                            self?.onUIReady?()
                        }
                    }
                }
            }
        }
        
}
