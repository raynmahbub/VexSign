import Foundation
import OSLog
import NimbleExtensions

enum AnalyticsMetric: String, Codable, CaseIterable, Identifiable, Sendable {
    case appsSigned, appsInstalled, certificatesAdded, tweaksInjected, repositoriesAdded
    var id: String { rawValue }
    var title: String {
        switch self {
        case .appsSigned: return .localized("Apps Signed")
        case .appsInstalled: return .localized("Apps Installed")
        case .certificatesAdded: return .localized("Certificates Added")
        case .tweaksInjected: return .localized("Tweaks Injected")
        case .repositoriesAdded: return .localized("Repositories Added")
        }
    }
}
struct AnalyticsBucket: Codable, Identifiable, Sendable {
    var id: String { "\(date.timeIntervalSince1970):\(metric.rawValue)" }
    let date: Date
    let metric: AnalyticsMetric
    var count: Int
}

actor AnalyticsStore {
    static let shared = AnalyticsStore()
    private var buckets: [AnalyticsBucket]?
    // Serial task chain prevents actor reentrancy from losing concurrent events during I/O.
    private var pending: Task<Void, Never>?
    func record(_ metric: AnalyticsMetric, count: Int = 1) async {
        guard count > 0 else { return }
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
