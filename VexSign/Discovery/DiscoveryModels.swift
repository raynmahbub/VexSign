import Foundation

struct DiscoveryApp: Codable, Identifiable, Hashable, Sendable {
    let id: String // source + bundle ID: never silently conflates two publishers
    let source: String
    let bundleIdentifier: String
    let name: String
    let summary: String
    let developer: String
    let category: String
    let version: String
    let icon: URL?
    let download: URL?
    let updated: Date?
    let releases: Int
    var searchText: String { "\(name) \(bundleIdentifier) \(summary) \(developer) \(category)".folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current) }
}

struct CollectionItem: Identifiable { let id: String; let title: String; let apps: [DiscoveryApp] }
struct CategoryItem: Identifiable { let name: String; let apps: [DiscoveryApp]; var id: String { name } }

/// Canonical bundle ID deduplication grouping multi-source versions together.
struct CanonicalAppGroup: Identifiable, Hashable, Sendable {
    var id: String { bundleIdentifier }
    let bundleIdentifier: String
    let primaryApp: DiscoveryApp
    let versions: [DiscoveryApp]
    var hasMultipleSources: Bool { versions.count > 1 }
    var sourceCount: Int { Set(versions.map(\.source)).count }
}

struct DiscoverySignals: Codable, Sendable {
    var favorites: Set<String> = []
    /// Local download requests, not fabricated global popularity or install counts.
    var downloads: [String: Int] = [:]
    /// Explicit user-assigned source trust, not publisher-controlled feed metadata.
    var trust: [String: Double] = [:]
}

enum DiscoveryRanking {
    static func score(_ app: DiscoveryApp, signals: DiscoverySignals, now: Date = Date()) -> Double {
        let age = max(0, now.timeIntervalSince(app.updated ?? .distantPast) / 86_400)
        let recency = exp(-age / 30)
        let frequency = min(Double(max(0, app.releases)), 24) / 24
        return log1p(Double(max(0, signals.downloads[app.id, default: 0]))) * 2
            + recency * 3 + frequency
            + min(1, max(0, signals.trust[app.source, default: 0.5])) * 2
            + (signals.favorites.contains(app.id) ? 4 : 0)
    }
}

actor DiscoveryIndex {
    private var apps: [DiscoveryApp] = []
    private var searchable: [String: String] = [:]
    func replace(_ apps: [DiscoveryApp]) {
        self.apps = apps
        searchable = Dictionary(apps.map { ($0.id, $0.searchText) }, uniquingKeysWith: { first, _ in first })
    }

    /// Groups apps by canonical bundle identifier to deduplicate multi-source listings.
    func canonicalGroups(for candidateApps: [DiscoveryApp]? = nil) -> [CanonicalAppGroup] {
        let pool = candidateApps ?? apps
        let grouped = Dictionary(grouping: pool, by: \.bundleIdentifier)
        return grouped.compactMap { bundleID, list in
            guard let primary = list.max(by: { lhs, rhs in
                (lhs.updated ?? .distantPast) < (rhs.updated ?? .distantPast)
            }) else { return nil }
            let sortedList = list.sorted {
                ($0.updated ?? .distantPast) > ($1.updated ?? .distantPast)
            }
            return CanonicalAppGroup(bundleIdentifier: bundleID, primaryApp: primary, versions: sortedList)
        }.sorted { $0.primaryApp.name.localizedStandardCompare($1.primaryApp.name) == .orderedAscending }
    }

    /// Returns all available source variants and versions for a given bundle identifier.
    func versions(for bundleIdentifier: String) -> [DiscoveryApp] {
        apps.filter { $0.bundleIdentifier == bundleIdentifier }
            .sorted { ($0.updated ?? .distantPast) > ($1.updated ?? .distantPast) }
    }

    /// An empty query matches every app (allSatisfy over no words is true), which is
    /// how the view lists everything before the user types.
    ///
    /// Written as separate steps on purpose: the chained filter/map/sorted/map with
    /// inferred tuples blew past the type checker's expression budget.
    func search(_ query: String, signals: DiscoverySignals) -> [DiscoveryApp] {
        let folded = query.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let words: [String] = folded.split(whereSeparator: \.isWhitespace).map(String.init)

        let matched: [DiscoveryApp] = apps.filter { app in
            let haystack: String = searchable[app.id, default: ""]
            return words.allSatisfy { word in haystack.contains(word) }
        }

        let now = Date()
        let ranked: [(app: DiscoveryApp, score: Double)] = matched.map { app in
            (app, DiscoveryRanking.score(app, signals: signals, now: now))
        }

        let ordered: [(app: DiscoveryApp, score: Double)] = ranked.sorted { lhs, rhs in
            if lhs.score == rhs.score { return lhs.app.id < rhs.app.id }
            return lhs.score > rhs.score
        }

        return ordered.map { entry in entry.app }
    }
}
