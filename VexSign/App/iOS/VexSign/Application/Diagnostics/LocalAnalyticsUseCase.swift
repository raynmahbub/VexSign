import Foundation

@MainActor
final class LocalAnalyticsUseCase {
    private let provider: LocalAnalyticsProviding
    init(provider: LocalAnalyticsProviding) { self.provider = provider }
    func load() async throws -> [AnalyticsBucket] { try await provider.load() }
}
