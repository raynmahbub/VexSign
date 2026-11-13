//
//  RefreshAndDownloadsSettingsView.swift
//  VexSign — Refresh & Downloads Settings
//

import SwiftUI
import UIKit
import NimbleViews
import NimbleExtensions

struct RefreshAndDownloadsSettingsView: View {
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage(BackgroundAutomationPreferences.enabledKey) private var automationEnabled: Bool = false
    @AppStorage(BackgroundAutomationPreferences.intervalKey) private var intervalRaw: Int = BackgroundAutomationInterval.everySixHours.rawValue
    @AppStorage(DownloadPreferences.wifiOnlyKey) private var wifiOnlyDownloads: Bool = false
    @AppStorage(DownloadPreferences.chargeOnlyKey) private var chargeOnlyDownloads: Bool = false
    @ObservedObject private var updatePreferences = UpdateMatchingPreferences.shared

    @State private var systemRefreshStatus: UIBackgroundRefreshStatus = UIApplication.shared.backgroundRefreshStatus

    private var selectedInterval: BackgroundAutomationInterval {
        BackgroundAutomationInterval(rawValue: intervalRaw) ?? .everySixHours
    }

    private var isSystemRefreshAvailable: Bool {
        systemRefreshStatus == .available
    }

    private var systemRefreshLabel: String {
        switch systemRefreshStatus {
        case .available:
            return .localized("Available")
        case .denied:
            return .localized("Disabled in iOS Settings")
        case .restricted:
            return .localized("Restricted by System Policy")
        @unknown default:
            return .localized("Unknown")
        }
    }

    var body: some View {
        NBList(.localized("Refresh & Downloads")) {
            // MARK: - Background Refresh
            NBSection(.localized("BACKGROUND REFRESH")) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.pink.opacity(0.18))
                            .frame(width: 32, height: 32)
                        Image(systemName: "gearshape")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.pink)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(.localized("iOS Background App Refresh"))
                            .font(.subheadline.weight(.semibold))
                        Text(systemRefreshLabel)
                            .font(.caption2)
                            .foregroundStyle(isSystemRefreshAvailable ? .purple : .secondary)
                    }

                    Spacer()

                    HStack(spacing: 4) {
                        Circle()
                            .fill(isSystemRefreshAvailable ? Color.green : Color.orange)
                            .frame(width: 6, height: 6)
                        Text(isSystemRefreshAvailable ? String.localized("ON") : String.localized("OFF"))
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(isSystemRefreshAvailable ? Color.green : .orange)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background((isSystemRefreshAvailable ? Color.green : Color.orange).opacity(0.12), in: Capsule())
                }
                .padding(.vertical, 2)

                if !isSystemRefreshAvailable {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.open(url)
                        }
                    } label: {
                        Label(.localized("Enable in iOS Settings"), systemImage: "arrow.up.right.circle")
                            .font(.subheadline)
                    }
                }

                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.red.opacity(0.18))
                            .frame(width: 32, height: 32)
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.red)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(.localized("Scheduled Update Checks"))
                            .font(.subheadline.weight(.semibold))
                        Text(.localized("Refresh sources and check for updates"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Toggle("", isOn: $automationEnabled)
                        .labelsHidden()
                        .tint(Color.red)
                }
                .padding(.vertical, 2)
            } footer: {
                Text(.localized("Uses the same Background Automation schedule as Settings → Automation. iOS runs background tasks opportunistically when system refresh is allowed."))
            }

            // MARK: - Refresh Interval
            NBSection(.localized("REFRESH INTERVAL")) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.purple.opacity(0.18))
                            .frame(width: 32, height: 32)
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.purple)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(.localized("Minimum Interval"))
                            .font(.subheadline.weight(.semibold))
                        Text(.localized("Requested frequency for background runs"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Menu {
                        Picker(.localized("Interval"), selection: $intervalRaw) {
                            ForEach(BackgroundAutomationInterval.allCases) { interval in
                                Text(interval.title).tag(interval.rawValue)
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(selectedInterval.title)
                                .font(.subheadline.weight(.semibold))
                            Image(systemName: "chevron.down")
                                .font(.caption2.weight(.bold))
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Color.purple.opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .foregroundStyle(Color.purple)
                    }
                }
                .padding(.vertical, 2)
                .disabled(!automationEnabled)

                NavigationLink(destination: AutomationView()) {
                    Label(.localized("Automation Policy, Run Now & History"), systemImage: "bolt.badge.clock")
                }
            }

            // MARK: - Network Policies
            NBSection(.localized("NETWORK POLICIES")) {
                Toggle(isOn: $updatePreferences.autoUpdateWifiOnly) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(.localized("Wi-Fi Only for Automatic Updates"))
                            .font(.subheadline.weight(.semibold))
                        Text(.localized("Skips background update downloads on cellular or hotspot connections"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(Color.pink)

                Toggle(isOn: $wifiOnlyDownloads) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(.localized("Wi-Fi Only for Package Downloads"))
                            .font(.subheadline.weight(.semibold))
                        Text(.localized("Requires non-cellular Wi-Fi before starting new IPA downloads"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(Color.purple)

                Toggle(isOn: $chargeOnlyDownloads) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(.localized("Only While Charging"))
                            .font(.subheadline.weight(.semibold))
                        Text(.localized("Waits until power is connected before starting new downloads"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(Color.purple)

                NavigationLink(destination: DownloadsSettingsView()) {
                    Label(.localized("Parallel Slots & Display Options"), systemImage: "arrow.down.circle")
                }
            } footer: {
                Text(.localized("Network and power rules here directly control DownloadManager and scheduled background update passes."))
            }
        }
        .onAppear {
            DownloadPreferences.migrateLegacyRefreshPreferences()
            refreshSystemStatus()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                refreshSystemStatus()
            }
        }
        .onChange(of: automationEnabled) { _, _ in
            scheduleAutomation()
        }
        .onChange(of: intervalRaw) { _, _ in
            scheduleAutomation()
        }
    }

    private func refreshSystemStatus() {
        systemRefreshStatus = UIApplication.shared.backgroundRefreshStatus
    }

    private func scheduleAutomation() {
        (UIApplication.shared.delegate as? AppDelegate)?.scheduleAutomationMaintenance()
    }
}
