// MARK: - Unified catalog search
//
// Search is a pure, deterministic projection over validated snapshots. It never
// invents popularity or ratings, and it preserves every source listing for a
// bundle identifier instead of collapsing unrelated publishers.

import Foundation
import NimbleExtensions

struct CatalogSearchQuery: Equatable, Sendable {
    enum Sort: String, CaseIterable, Sendable {
        case name
        case updated
        case source
        case developer

        var displayName: String {
            switch self {
            case .name: .localized("Name")
            case .updated: .localized("Recently updated")
            case .source: .localized("Source")
            case .developer: .localized("Developer")
            }
        }
    }

    var text: String = ""
    var sourceIDs: Set<String> = []
    var developer: String = ""
    var minimumOSVersion: String?
    var sort: Sort = .name
    var ascending: Bool = true
}

enum CatalogSearch {
    static func search(snapshots: [CatalogSnapshot], query: CatalogSearchQuery) -> [CatalogSearchHit] {
        let apps = snapshots.flatMap(\.apps)
        return search(apps: apps, query: query)
    }

    static func search(apps: [CatalogAppRecord], query: CatalogSearchQuery) -> [CatalogSearchHit] {
        let needle = query.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let developerNeedle = query.developer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let groups = Dictionary(grouping: apps) { app in
            CatalogIdentity.bundleKey(app.bundleIdentifier) ?? app.id
        }

        var hits: [CatalogSearchHit] = []
        for (key, listings) in groups {
            guard !listings.isEmpty else { continue }
            let allowed = listings.filter { app in
                if !query.sourceIDs.isEmpty, !query.sourceIDs.contains(app.sourceID) { return false }
                if !developerNeedle.isEmpty,
                   !(app.developer?.lowercased().contains(developerNeedle) ?? false) { return false }
                if let minimumOSVersion = query.minimumOSVersion,
                   let appMinimum = app.latest?.minimumOSVersion,
                   let order = VersionOrder.precedence(appMinimum, minimumOSVersion),
                   order == .orderedDescending { return false }
                guard !needle.isEmpty else { return true }
                return app.name.lowercased().contains(needle)
                    || app.bundleIdentifier.lowercased().contains(needle)
                    || (app.developer?.lowercased().contains(needle) ?? false)
            }
            guard !allowed.isEmpty else { continue }
            let ordered = allowed.sorted { lhs, rhs in
                let result = _compare(lhs, rhs, sort: query.sort)
                return query.ascending ? result == .orderedAscending : result == .orderedDescending
            }
            hits.append(CatalogSearchHit(
                bundleKey: key,
                name: ordered.first?.name ?? key,
                developer: ordered.first?.developer,
                listings: ordered.map(CatalogSearchHit.Listing.init)
            ))
        }
        return hits.sorted { lhs, rhs in
            let result = _compare(lhs.selected ?? CatalogueEmpty.app, rhs.selected ?? CatalogueEmpty.app, sort: query.sort)
            return query.ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    private static func _compare(_ lhs: CatalogAppRecord, _ rhs: CatalogAppRecord, sort: Sort) -> ComparisonResult {
        switch sort {
        case .name:
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        case .source:
            let bySource = lhs.sourceName.localizedCaseInsensitiveCompare(rhs.sourceName)
            return bySource == .orderedSame ? _compare(lhs, rhs, sort: .name) : bySource
        case .developer:
            let byDeveloper = (lhs.developer ?? "").localizedCaseInsensitiveCompare(rhs.developer ?? "")
            return byDeveloper == .orderedSame ? _compare(lhs, rhs, sort: .name) : byDeveloper
        case .updated:
            let left = lhs.latest?.date ?? ""
            let right = rhs.latest?.date ?? ""
            if left == right { return _compare(lhs, rhs, sort: .name) }
            return left.compare(right)
        }
    }
}

private enum CatalogueEmpty {
    static let app = CatalogAppRecord(
        id: "", sourceID: "", sourceName: "", sourceURL: "", bundleIdentifier: "", name: "",
        developer: nil, summary: nil, description: nil, iconURL: nil, screenshotURLs: [],
        category: nil, tintColor: nil, releases: [], permissions: [], extra: [:],
        fetchedAt: .distantPast, metadataIsVerified: false
    )
}
