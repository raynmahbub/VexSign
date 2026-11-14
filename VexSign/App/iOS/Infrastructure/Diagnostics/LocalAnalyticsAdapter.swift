import Foundation

@MainActor
final class LocalAnalyticsAdapter: LocalAnalyticsProviding {
    func load() async throws -> [AnalyticsBucket] { try await AnalyticsStore.shared.load() }
}
