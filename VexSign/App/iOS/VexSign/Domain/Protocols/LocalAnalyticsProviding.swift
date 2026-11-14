import Foundation

@MainActor
protocol LocalAnalyticsProviding: AnyObject {
    func load() async throws -> [AnalyticsBucket]
}
