import SwiftUI
import Charts
import NimbleExtensions

struct AnalyticsView: View {
    enum Period: String, CaseIterable {
        case daily = "Daily", weekly = "Weekly", monthly = "Monthly"
        var title: String {
            switch self {
            case .daily: return .localized("Daily")
            case .weekly: return .localized("Weekly")
            case .monthly: return .localized("Monthly")
            }
        }
    }
    @State private var period = Period.daily
    @State private var metric = AnalyticsMetric.appsSigned
    @State private var buckets: [AnalyticsBucket] = []
    @State private var storage: Int64 = 0
    @State private var certificates = 0
    @State private var error: String?
    private var chart: [AnalyticsBucket] {
        let calendar = Calendar.current
        let component: Calendar.Component = period == .daily ? .day : period == .weekly ? .weekOfYear : .month
        let groups = Dictionary(grouping: buckets.filter { $0.metric == metric }) {
            calendar.dateInterval(of: component, for: $0.date)?.start ?? $0.date
        }
        return groups.map { AnalyticsBucket(date: $0.key, metric: metric, count: $0.value.reduce(0) { $0 + $1.count }) }.sorted { $0.date < $1.date }
    }
    var body: some View {
        List {
            Section(.localized("Local Activity")) {
                Picker(.localized("Period"), selection: $period) { ForEach(Period.allCases, id: \.self) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                Picker(.localized("Metric"), selection: $metric) { ForEach(AnalyticsMetric.allCases) { Text($0.title).tag($0) } }
                Chart(chart) { point in BarMark(x: .value(.localized("Date"), point.date), y: .value(.localized("Count"), point.count)) }.frame(height: 230)
                Text(String.localized("Total: %lld", arguments: chart.reduce(0) { $0 + $1.count })).font(.headline)
                Text(.localized("Private, on-device counts from this version onward. OTA handoff is not proof of installation. No historical counts are invented.")).font(.caption).foregroundStyle(.secondary)
            }
            Section(.localized("Current Inventory")) {
                LabeledContent(.localized("Certificates"), value: String(certificates))
                LabeledContent(.localized("Documents Storage"), value: ByteCountFormatter.string(fromByteCount: storage, countStyle: .file))
            }
            if let error { Text(error).foregroundStyle(.red) }
        }.navigationTitle(.localized("Analytics"))
            .task {
                do { buckets = try await AnalyticsStore.shared.load() } catch { self.error = error.localizedDescription }
                certificates = Storage.shared.getAllCertificates().count
                let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                storage = await Task.detached(priority: .utility) {
                    guard let directory, let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else { return Int64(0) }
                    var total: Int64 = 0
                    // `nextObject()` rather than `for … in files`: NSEnumerator's
                    // `makeIterator()` is unavailable from asynchronous contexts.
                    while let url = files.nextObject() as? URL {
                        if Task.isCancelled { break }
                        if let value = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), value.isRegularFile == true { total += Int64(value.fileSize ?? 0) }
                    }
                    return total
                }.value
            }
    }
}

