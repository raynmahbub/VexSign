//
//  TroubleshootingCenterView.swift
//  VexSign
//
//  A native SwiftUI view over the actual diagnostic journal. Filters affect both
//  what is shown and what is exported; no data is generated for display.
//

import SwiftUI
import NimbleExtensions

struct TroubleshootingCenterView: View {
    @EnvironmentObject private var appContainer: AppContainer
    @State private var viewModel: TroubleshootingCenterViewModel?

    var body: some View {
        Group {
            if let viewModel {
                TroubleshootingCenterContent(viewModel: viewModel)
            } else {
                ProgressView()
                    .accessibilityLabel(Text(.localized("Loading diagnostics")))
                    .onAppear { viewModel = appContainer.makeTroubleshootingViewModel() }
            }
        }
        .navigationTitle(Text(.localized("Troubleshooting Center")))
        .accessibilityIdentifier(A11y.Diagnostics.troubleshooting)
    }
}

private struct TroubleshootingCenterContent: View {
    @ObservedObject var viewModel: TroubleshootingCenterViewModel

    var body: some View {
        List {
            Section {
                Text(verbatim: String.localized(
                    "%lld structured events retained locally. The journal is bounded and rotates older data.",
                    arguments: Int64(viewModel.events.count)
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                if let notice = viewModel.journalNotice {
                    Label(notice, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                ForEach(viewModel.metricSummaries) { summary in
                    HStack {
                        Text(summary.title)
                        Spacer()
                        Text(verbatim: String.localized("%lld reported", arguments: Int64(summary.count)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                Text(.localized("MetricKit reports arrive under iOS control, on a physical device. No reports here does not mean no crash occurred."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } header: {
                Text(.localized("Diagnostics status"))
            }

            Section {
                Menu {
                    ForEach(DiagnosticCategory.allCases) { category in
                        Button {
                            if viewModel.selectedCategories.contains(category) {
                                viewModel.selectedCategories.remove(category)
                            } else {
                                viewModel.selectedCategories.insert(category)
                            }
                        } label: {
                            Label(
                                category.rawValue,
                                systemImage: viewModel.selectedCategories.contains(category) ? "checkmark.circle.fill" : "circle"
                            )
                        }
                    }
                } label: {
                    Text(verbatim: String.localized(
                        "Categories: %@",
                        arguments: viewModel.selectedCategories.isEmpty
                            ? String.localized("All")
                            : String.localized("%lld selected", arguments: Int64(viewModel.selectedCategories.count))
                    ))
                }
                .accessibilityLabel(Text(.localized("Filter by category")))
                .accessibilityIdentifier(A11y.Diagnostics.categoryFilter)

                TextField(.localized("Operation or task ID"), text: $viewModel.operationID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel(Text(.localized("Operation or task ID")))
                    .accessibilityHint(Text(.localized("Only matching events are shown and exported.")))
                    .accessibilityIdentifier(A11y.Diagnostics.operationFilter)

                Toggle(isOn: $viewModel.limitDateRange) {
                    Text(.localized("Limit to date range"))
                }
                if viewModel.limitDateRange {
                    DatePicker(.localized("From"), selection: $viewModel.fromDate, displayedComponents: [.date, .hourAndMinute])
                    DatePicker(.localized("To"), selection: $viewModel.toDate, displayedComponents: [.date, .hourAndMinute])
                }
            } header: {
                Text(.localized("Filters"))
            }

            Section {
                if viewModel.filteredEvents.isEmpty {
                    Text(.localized("No recorded event matches these filters."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.filteredEvents) { event in
                        eventRow(event)
                    }
                }
            } header: {
                Text(verbatim: String.localized(
                    "Recorded events (%lld)",
                    arguments: Int64(viewModel.filteredEvents.count)
                ))
            }
            .accessibilityIdentifier(A11y.Diagnostics.events)

            Section {
                Button {
                    viewModel.exportFilteredBundle()
                } label: {
                    HStack {
                        Label(.localized("Export filtered diagnostic bundle"), systemImage: "square.and.arrow.up")
                        Spacer()
                        if viewModel.isExporting { ProgressView() }
                    }
                }
                .disabled(viewModel.isExporting)
                .accessibilityHint(Text(.localized("Opens the share sheet with the selected events and outcomes.")))
                .accessibilityIdentifier(A11y.Diagnostics.exportFiltered)
                Text(.localized("A filtered export omits free-form logs and contains only the selected events and matching operation outcomes."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } header: {
                Text(.localized("Export"))
            }
        }
        .dismissableKeyboard()
        .task { await viewModel.refresh() }
    }

    private func eventRow(_ event: DiagnosticEvent) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Image(systemName: event.severity == .error || event.severity == .fault
                      ? "exclamationmark.triangle.fill" : "info.circle")
                    .foregroundStyle(event.severity == .error || event.severity == .fault ? .red : .secondary)
                    .accessibilityHidden(true)
                Text(event.code)
                    .font(.caption2.monospaced())
                Spacer()
                Text(event.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(event.userMessage)
                .font(.subheadline)
            if let task = viewModel.taskTitle(for: event) {
                Text(verbatim: String.localized("Task: %@", arguments: task))
                    .font(.caption)
                    .foregroundStyle(.blue)
            }
            if let operationID = event.operationID {
                Text(verbatim: String.localized("Operation: %@", arguments: operationID))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let detail = event.developerDetail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let recovery = event.recoverySuggestion {
                Text(recovery)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            if !event.metadata.isEmpty {
                Text(verbatim: Self.metadataText(event.metadata))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(A11y.Diagnostics.eventRowPrefix + event.code)
    }

    private static func metadataText(_ metadata: [String: String]) -> String {
        metadata.keys.sorted().map { "\($0)=\(metadata[$0] ?? "")" }.joined(separator: " · ")
    }
}
