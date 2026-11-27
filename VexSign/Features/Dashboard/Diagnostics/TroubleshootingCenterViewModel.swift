//
//  TroubleshootingCenterViewModel.swift
//  VexSign
//
//  Reads the real diagnostic journal and the existing task center. Every row is
//  backed by a recorded event; the view model does not generate sample data,
//  scores or pass/fail judgements.
//

import Foundation
import Combine
import NimbleExtensions

@MainActor
final class TroubleshootingCenterViewModel: ObservableObject {
    struct MetricSummary: Identifiable {
        let code: String
        let title: String
        let count: Int
        var id: String { code }
    }

    @Published private(set) var events: [DiagnosticEvent] = []
    @Published private(set) var taskNames: [String: String] = [:]
    @Published private(set) var journalNotice: String?
    @Published private(set) var isExporting = false
    @Published var selectedCategories: Set<DiagnosticCategory> = []
    @Published var operationID = ""
    @Published var limitDateRange = false
    @Published var fromDate = Date().addingTimeInterval(-7 * 86_400)
    @Published var toDate = Date()

    private let journal: DiagnosticEventJournal
    private let outcomes: OperationOutcomeJournal
    private let platform: PlatformSystemAdapting
    private let taskCorrelation: TaskCorrelationService

    init(
        journal: DiagnosticEventJournal,
        outcomes: OperationOutcomeJournal,
        platform: PlatformSystemAdapting,
        taskCorrelation: TaskCorrelationService = TaskCorrelationService()
    ) {
        self.journal = journal
        self.outcomes = outcomes
        self.platform = platform
        self.taskCorrelation = taskCorrelation
    }

    var filter: DiagnosticExportFilter {
        DiagnosticExportFilter(
            categories: selectedCategories.isEmpty ? nil : selectedCategories,
            from: limitDateRange ? fromDate : nil,
            to: limitDateRange ? toDate : nil,
            operationID: operationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : operationID.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    var filteredEvents: [DiagnosticEvent] {
        events.filter { filter.matches($0) }.sorted { $0.timestamp > $1.timestamp }
    }

    var metricSummaries: [MetricSummary] {
        var counts: [String: Int] = [:]
        for event in events where event.code.hasPrefix("VEX-MK-") {
            counts[event.code, default: 0] += 1
        }
        return counts.keys.sorted().map { code in
            MetricSummary(
                code: code,
                title: Self.metricTitle(code),
                count: counts[code] ?? 0
            )
        }
    }

    func refresh() async {
        events = await journal.all()
        let notice = await journal.consumeRecoveryAction()
        if let notice { journalNotice = notice }

        // Correlate by the IDs the task center already records. A task title is
        // shown only when an ID actually matches; no placeholder is invented.
        taskNames = taskCorrelation.correlatedTitles()
    }

    func exportFilteredBundle() {
        guard !isExporting else { return }
        isExporting = true
        let activeFilter = filter
        Task { @MainActor in
            let url = await DiagnosticBundleExporter.createDiagnosticBundle(
                outcomes: outcomes,
                events: journal,
                filter: activeFilter
            )
            isExporting = false
            if let url {
                platform.shareItems([url])
            } else {
                platform.notifyError(String.localized("Could not create the filtered diagnostic bundle."), sticky: false)
            }
        }
    }

    func taskTitle(for event: DiagnosticEvent) -> String? {
        guard let operationID = event.operationID else { return nil }
        return taskNames[operationID]
    }

    private static func metricTitle(_ code: String) -> String {
        switch code {
        case DiagnosticEventCode.metricKitCrash: return .localized("Crash reports")
        case DiagnosticEventCode.metricKitHang: return .localized("Hang reports")
        case DiagnosticEventCode.metricKitCPU: return .localized("CPU exceptions")
        case DiagnosticEventCode.metricKitLaunch: return .localized("Launch diagnostics")
        case DiagnosticEventCode.metricKitDisk: return .localized("Disk-write exceptions")
        default: return .localized("System reports")
        }
    }
}
