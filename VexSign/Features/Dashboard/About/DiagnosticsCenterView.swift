//
//  DiagnosticsCenterView.swift
//  VexSign — Unified Diagnostics & Health Center
//

import SwiftUI
import NimbleViews
import NimbleExtensions

struct DiagnosticsCenterView: View {
    @EnvironmentObject private var appContainer: AppContainer
    @State private var viewModel: DiagnosticsCenterViewModel?

    init(viewModel: DiagnosticsCenterViewModel? = nil) {
        self._viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        Group {
            if let viewModel {
                DiagnosticsCenterContent(viewModel: viewModel)
            } else {
                ProgressView()
                    .onAppear {
                        let container = appContainer
                        viewModel = container.makeDiagnosticsViewModel()
                    }
            }
        }
    }
}

private struct DiagnosticsCenterContent: View {
    @ObservedObject var viewModel: DiagnosticsCenterViewModel

    var body: some View {
        let snapshot = viewModel.snapshot

        NBList(.localized("Diagnostics Center")) {
            if !snapshot.migrationWarnings.isEmpty {
                NBSection(.localized("Credential storage")) {
                    ForEach(snapshot.migrationWarnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }

            NBSection(.localized("System Overview")) {
                summaryRow(
                    title: .localized("Certificates"),
                    value: snapshot.certificateCount == 0
                        ? .localized("None imported")
                        : .localized("%lld imported (%lld expiring soon)", arguments: snapshot.certificateCount, snapshot.expiringCertificateCount),
                    icon: "checkmark.seal",
                    color: snapshot.expiringCertificateCount > 0 ? .orange : .green
                )

                summaryRow(
                    title: .localized("Repositories"),
                    value: .localized("%lld installed (%lld failing)", arguments: snapshot.repositoryCount, snapshot.failingRepositoryCount),
                    icon: "globe",
                    color: snapshot.failingRepositoryCount > 0 ? .orange : .blue
                )

                summaryRow(
                    title: .localized("Stale Sources"),
                    value: snapshot.staleSourceCount == 0
                        ? .localized("All fresh")
                        : .localized("%lld need refresh", arguments: snapshot.staleSourceCount),
                    icon: "arrow.triangle.2.circlepath",
                    color: snapshot.staleSourceCount > 0 ? .orange : .green
                )
            }

            NBSection(.localized("Certificates")) {
                if snapshot.certificates.isEmpty {
                    Text(.localized("No certificates imported"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(snapshot.certificates) { cert in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(cert.displayName)
                                    .font(.subheadline.weight(.medium))
                                Spacer()
                                if let days = cert.daysRemaining {
                                    Text(days < 0 ? String.localized("Expired") : String.localized("%lldd left", arguments: days))
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(days < 7 ? .orange : .green)
                                }
                            }
                            if cert.isRevoked {
                                Text(.localized("Revoked"))
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                }
            }

            if !snapshot.failingSourceNames.isEmpty {
                NBSection(.localized("Failing Repositories")) {
                    ForEach(snapshot.failingSourceNames, id: \.self) { sourceName in
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(sourceName)
                            Spacer()
                            Text(.localized("Failed"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            NBSection(.localized("Recent Task History")) {
                if snapshot.recentTasks.isEmpty {
                    Text(.localized("No tasks recorded yet"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(snapshot.recentTasks) { task in
                        HStack {
                            Image(systemName: task.iconName)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(task.title)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                Text(task.phaseTitle)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            NBSection(.localized("Security Verification")) {
                if viewModel.securityChecks.isEmpty {
                    Text(.localized("No security checks were available on this device."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.securityChecks) { check in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: Self.securitySymbol(check.status))
                                .foregroundStyle(Self.securityColor(check.status))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(check.title)
                                    .font(.subheadline.weight(.medium))
                                Text(check.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            NBSection(.localized("Export & Logs")) {
                NavigationLink(destination: TroubleshootingCenterView()) {
                    Label(.localized("Troubleshooting Center"), systemImage: "wrench.and.screwdriver")
                }
                .accessibilityIdentifier(A11y.Diagnostics.troubleshooting)

                NavigationLink(destination: LogsHistoryView(inNavigationStack: false)) {
                    Label(.localized("View Logs History"), systemImage: "text.alignleft")
                }

                Button {
                    viewModel.exportDiagnostics()
                } label: {
                    HStack {
                        Label(.localized("Export Diagnostic Bundle"), systemImage: "square.and.arrow.up")
                        Spacer()
                        if viewModel.isExporting {
                            ProgressView()
                        }
                    }
                }
                .disabled(viewModel.isExporting)
            }
        }
        .onAppear {
            viewModel.refresh()
        }
    }

    /// Status is shown per check. A check that could not run is never drawn as a
    /// green tick, and warnings are visually distinct from failures.
    private static func securitySymbol(_ status: SecurityCheckStatus) -> String {
        switch status {
        case .passed: return "checkmark.shield"
        case .warning: return "exclamationmark.shield"
        case .failed: return "xmark.shield"
        case .unknown: return "questionmark.circle"
        case .unsupported: return "minus.circle"
        }
    }

    private static func securityColor(_ status: SecurityCheckStatus) -> Color {
        switch status {
        case .passed: return .green
        case .warning: return .orange
        case .failed: return .red
        case .unknown, .unsupported: return .secondary
        }
    }

    private func summaryRow(title: String, value: String, icon: String, color: Color) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 24)
            Text(title)
            Spacer()
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
