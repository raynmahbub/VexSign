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

extension DiscoveryApp {
    /// A deterministic preference between two listings of the same bundle identifier.
    ///
    /// Newest date first, then the higher version, then the lower source key, then the id. Every
    /// step is decidable and stable, so two runs over the same catalogs choose the same primary
    /// listing — which the previous `max(by: date)` did not guarantee on a tie, and §13 asks for
    /// explicitly rather than a silent pick.
    static func isPreferred(_ lhs: DiscoveryApp, over rhs: DiscoveryApp) -> Bool {
        let leftDate = lhs.updated ?? .distantPast
        let rightDate = rhs.updated ?? .distantPast
        if leftDate != rightDate { return leftDate > rightDate }

        if let order = VersionOrder.precedence(lhs.version, rhs.version), order != .orderedSame {
            return order == .orderedDescending
        }

        let leftSource = CatalogIdentity.sourceKey(lhs.source) ?? lhs.source
        let rightSource = CatalogIdentity.sourceKey(rhs.source) ?? rhs.source
        if leftSource != rightSource { return leftSource < rightSource }

        return lhs.id < rhs.id
    }
}

struct CollectionItem: Identifiable { let id: String; let title: String; let apps: [DiscoveryApp] }
struct CategoryItem: Identifiable { let name: String; let apps: [DiscoveryApp]; var id: String { name } }

/// Canonical bundle ID deduplication grouping multi-source versions together.
struct CanonicalAppGroup: Identifiable, Hashable, Sendable {
    var id: String { bundleIdentifier }
    let bundleIdentifier: String
    let primaryApp: DiscoveryApp
    let versions: [DiscoveryApp]
    /// Whether more than one repository publishes this bundle ID.
    ///
    /// Publisher breadth, so it is derived from the sources and not from the number of
    /// versions: one repo listing 1.0 and 2.0 of the same app is still one publisher, and a
    /// caller asking about sources was being answered with a version count.
    var hasMultipleSources: Bool { sourceCount > 1 }
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

    /// Groups listings by canonical bundle identifier, so two publishers of one app are one
    /// entry and two casings of one identifier are not two applications.
    ///
    /// The primary listing is chosen by `DiscoveryApp.isPreferred`, which is a total order: the
    /// old `max(by: date)` picked whichever value the dictionary happened to enumerate first
    /// whenever two sources published the same date.
    func canonicalGroups(for candidateApps: [DiscoveryApp]? = nil) -> [CanonicalAppGroup] {
        let pool = candidateApps ?? apps
        let grouped = Dictionary(grouping: pool) { app in
            CatalogIdentity.bundleKey(app.bundleIdentifier) ?? app.bundleIdentifier
        }
        return grouped.compactMap { bundleID, list -> CanonicalAppGroup? in
            let sortedList = list.sorted { DiscoveryApp.isPreferred($0, over: $1) }
            guard let primary = sortedList.first else { return nil }
            return CanonicalAppGroup(bundleIdentifier: bundleID, primaryApp: primary, versions: sortedList)
        }.sorted { lhs, rhs in
            if lhs.primaryApp.name == rhs.primaryApp.name { return lhs.bundleIdentifier < rhs.bundleIdentifier }
            return lhs.primaryApp.name.localizedStandardCompare(rhs.primaryApp.name) == .orderedAscending
        }
    }

    /// Returns all available source variants and versions for a given bundle identifier.
    ///
    /// The argument is normalized the same way the pool was, so a caller holding the identifier
    /// exactly as one publisher spelled it still finds every other publisher's listing.
    func versions(for bundleIdentifier: String) -> [DiscoveryApp] {
        let key = CatalogIdentity.bundleKey(bundleIdentifier) ?? bundleIdentifier
        return apps
            .filter { (CatalogIdentity.bundleKey($0.bundleIdentifier) ?? $0.bundleIdentifier) == key }
            .sorted { DiscoveryApp.isPreferred($0, over: $1) }
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
