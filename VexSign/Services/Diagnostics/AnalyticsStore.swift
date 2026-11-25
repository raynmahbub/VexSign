import Foundation
import OSLog
import NimbleExtensions

/// Local counters are opt-in. With this off (the default) nothing is recorded,
/// so a build that wants RyukSign's "no analytics" behaviour can keep it off.
enum LocalAnalyticsPreferences {
    static let enabledKey = "VexSign.localAnalyticsEnabled"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }
}

actor AnalyticsStore {
    static let shared = AnalyticsStore()
    private var buckets: [AnalyticsBucket]?
    // Serial task chain prevents actor reentrancy from losing concurrent events during I/O.
    private var pending: Task<Void, Never>?
    func record(_ metric: AnalyticsMetric, count: Int = 1) async {
        guard count > 0, LocalAnalyticsPreferences.isEnabled else { return }
        let prior = pending
        let task = Task {
            await prior?.value
            await self.append(metric, count: count)
        }
        pending = task
        await task.value
    }
    private func append(_ metric: AnalyticsMetric, count: Int) async {
        do {
            var values = try await load()
            let date = Calendar.current.startOfDay(for: Date())
            values.removeAll { $0.date < Date(timeIntervalSinceNow: -366 * 86_400) }
            if let i = values.firstIndex(where: { $0.date == date && $0.metric == metric }) { values[i].count += count }
            else { values.append(.init(date: date, metric: metric, count: count)) }
            try await EcosystemDatabase.shared.write(values, key: "analytics.daily")
            buckets = values
        } catch { Logger.misc.error("Unable to persist local analytics: \(error.localizedDescription)") }
    }
    func load() async throws -> [AnalyticsBucket] {
        if let buckets { return buckets }
        let loaded = try await EcosystemDatabase.shared.read("analytics.daily", as: [AnalyticsBucket].self) ?? []
        buckets = loaded
        return loaded
    }
}
