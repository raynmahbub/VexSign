//
//  AutomationJobStatusView.swift
//  VexSign
//
//  Honest status for durable maintenance jobs. The system chooses when a
//  background task actually runs; this screen reports the last verified job
//  outcome, the next eligible time and whether background refresh is available.
//

import SwiftUI
import UIKit
import NimbleViews
import NimbleExtensions

struct AutomationJobStatusView: View {
    @State private var jobs: [AutomationJobDefinition] = []
    @State private var backgroundRefresh: UIBackgroundRefreshStatus = .restricted

    var body: some View {
        NBList(.localized("Automation Status")) {
            Section {
                HStack {
                    Text(.localized("Background refresh"))
                    Spacer()
                    Text(backgroundRefreshLabel)
                        .foregroundStyle(backgroundRefresh == .available ? .green : .secondary)
                        .font(.caption.weight(.semibold))
                }
                Text(.localized("iOS decides when background tasks launch. An interval is the earliest eligible time, not a guarantee of execution. Opening VexSign reconsiders eligible jobs as a foreground fallback."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if backgroundRefresh != .available {
                    Button {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        UIApplication.open(url)
                    } label: {
                        Label(.localized("Open iOS Settings"), systemImage: "arrow.up.right.circle")
                    }
                }
            }

            Section {
                if jobs.isEmpty {
                    Text(.localized("No automation jobs are registered.")).foregroundStyle(.secondary)
                }
                ForEach(jobs) { job in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(job.kind.rawValue.capitalized)
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(job.isEnabled ? .localized("Enabled") : .localized("Off"))
                                .font(.caption2)
                                .foregroundStyle(job.isEnabled ? .green : .secondary)
                        }
                        if let result = job.lastResult {
                            Text(result.message)
                                .font(.caption)
                            Text("\(result.status.rawValue.capitalized) · \(result.finishedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(.localized("Not run yet."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let next = job.nextEligibleAt {
                            Text(String.localized("Next eligible: %@", arguments: next.formatted(date: .abbreviated, time: .shortened)))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if job.consecutiveFailures > 0 {
                            Text(String.localized("%lld consecutive failure(s); backoff is applied.", arguments: job.consecutiveFailures))
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(.vertical, 3)
                }
            } header: {
                Text(.localized("PERSISTENT JOBS"))
            }
        }
        .task {
            backgroundRefresh = UIApplication.shared.backgroundRefreshStatus
            jobs = await PersistentAutomationEngine.shared.snapshot()
        }
    }

    private var backgroundRefreshLabel: String {
        switch backgroundRefresh {
        case .available: return .localized("Available")
        case .restricted: return .localized("Restricted")
        case .denied: return .localized("Denied")
        @unknown default: return .localized("Unknown")
        }
    }
}
