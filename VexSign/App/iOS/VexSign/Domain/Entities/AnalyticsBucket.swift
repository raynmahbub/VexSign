import Foundation

enum AnalyticsMetric: String, Codable, CaseIterable, Identifiable, Sendable {
    case appsSigned, appsInstalled, certificatesAdded, tweaksInjected, repositoriesAdded
    var id: String { rawValue }

}
struct AnalyticsBucket: Codable, Identifiable, Sendable {
    var id: String { "\(date.timeIntervalSince1970):\(metric.rawValue)" }
    let date: Date
    let metric: AnalyticsMetric
    var count: Int
}
