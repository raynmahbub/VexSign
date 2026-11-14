//
//  NotificationsSettingsView.swift
//  VexSign — Notifications & Live Activities Settings
//

import SwiftUI
import NimbleViews
import NimbleExtensions
import UserNotifications
import ActivityKit

struct NotificationsSettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var pushEnabled: Bool = false
    @State private var lockScreen: Bool = false
    @State private var notificationCenter: Bool = false
    @State private var banners: Bool = false
    @State private var sounds: Bool = false
    @State private var badges: Bool = false
    @State private var timeSensitive: Bool = false
    @State private var criticalAlerts: Bool = false
    @State private var scheduledSummary: Bool = false
    @State private var systemLiveActivitiesAuthorized: Bool = false

    @AppStorage(LiveActivityPreferences.enabledKey) private var liveActivitiesEnabled: Bool = true

    private var effectiveLiveActivitiesEnabled: Bool {
        liveActivitiesEnabled && systemLiveActivitiesAuthorized
    }

    var body: some View {
        NBList(.localized("Notifications")) {
            // MARK: - Notifications
            NBSection(.localized("NOTIFICATIONS")) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.purple.opacity(0.18))
                            .frame(width: 32, height: 32)
                        Image(systemName: "bell.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.purple)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(.localized("Notifications"))
                            .font(.subheadline.weight(.semibold))
                        Text(pushEnabled ? String.localized("Authorized in iOS Settings") : String.localized("Disabled in iOS Settings"))
                            .font(.caption2)
                            .foregroundStyle(pushEnabled ? .purple : .secondary)
                    }

                    Spacer()

                    statusPill(isOn: pushEnabled)
                }
                .padding(.vertical, 2)
            }

            // MARK: - Delivery Settings
            NBSection(.localized("DELIVERY SETTINGS")) {
                deliveryRow(icon: "lock.fill", title: .localized("Lock Screen"), isOn: lockScreen)
                deliveryRow(icon: "list.bullet.rectangle.fill", title: .localized("Notification Center"), isOn: notificationCenter)
                deliveryRow(icon: "rectangle.topthird.inset.filled", title: .localized("Banners"), isOn: banners)
                deliveryRow(icon: "speaker.wave.2.fill", title: .localized("Sounds"), isOn: sounds)
                deliveryRow(icon: "app.badge.fill", title: .localized("Badges"), isOn: badges)
                deliveryRow(icon: "clock.badge.exclamationmark.fill", title: .localized("Time Sensitive"), isOn: timeSensitive)
                deliveryRow(icon: "exclamationmark.triangle.fill", title: .localized("Critical Alerts"), isOn: criticalAlerts, isNA: !criticalAlerts)
                deliveryRow(icon: "clock.fill", title: .localized("Scheduled Summary"), isOn: scheduledSummary, isOff: !scheduledSummary)

                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.open(url)
                    }
                } label: {
                    HStack {
                        Image(systemName: "gearshape")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(.localized("Change in iOS Settings"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            // MARK: - Live Activities
            NBSection(.localized("LIVE ACTIVITIES")) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.pink.opacity(0.18))
                            .frame(width: 32, height: 32)
                        Image(systemName: "figure.run.circle")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.pink)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(.localized("Download & Signing Live Activities"))
                            .font(.subheadline.weight(.semibold))
                    Text(
                        !systemLiveActivitiesAuthorized
                            ? String.localized("Blocked by iOS Settings")
                            : (liveActivitiesEnabled ? String.localized("Enabled") : String.localized("Disabled"))
                    )
                    .font(.caption2)
                    .foregroundStyle(effectiveLiveActivitiesEnabled ? .purple : .secondary)
                    }

                    Spacer()

                    Toggle("", isOn: $liveActivitiesEnabled)
                        .labelsHidden()
                        .tint(Color.green)
                }
                .padding(.vertical, 2)

                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.pink.opacity(0.18))
                            .frame(width: 32, height: 32)
                        Image(systemName: "iphone")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.pink)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(.localized("System Live Activities & Dynamic Island"))
                            .font(.subheadline.weight(.semibold))
                        Text(systemLiveActivitiesAuthorized ? String.localized("Authorized in iOS Settings") : String.localized("Disabled in iOS Settings"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    statusPill(isOn: systemLiveActivitiesAuthorized)
                }
                .padding(.vertical, 2)

                if !systemLiveActivitiesAuthorized {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.open(url)
                        }
                    } label: {
                        Label(.localized("Enable Live Activities in iOS Settings"), systemImage: "arrow.up.right.circle")
                            .font(.subheadline)
                    }
                }
            } footer: {
                Text(.localized("Turns VexSign download and signing progress Live Activities on or off. iOS uses the same system authorization for Lock Screen Live Activities and Dynamic Island (iPhone 14 Pro or newer). When disabled, downloads fall back to standard progress notifications if allowed."))
            }
        }
        .onAppear {
            UserDefaults.standard.removeObject(forKey: LiveActivityPreferences.legacyDynamicIslandKey)
            refreshSystemSettings()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                refreshSystemSettings()
            }
        }
        .onChange(of: liveActivitiesEnabled) { _, enabled in
            if !enabled {
                DownloadManager.shared.dismissLiveActivityImmediately()
                SigningLiveActivityManager.shared.endAll()
            }
        }
    }

    @ViewBuilder
    private func deliveryRow(icon: String, title: String, isOn: Bool, isNA: Bool = false, isOff: Bool = false) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isNA || isOff ? Color.secondary.opacity(0.15) : Color.pink.opacity(0.16))
                    .frame(width: 28, height: 28)
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isNA || isOff ? .secondary : Color.pink)
            }

            Text(title)
                .font(.subheadline.weight(.medium))

            Spacer()

            if isNA {
                Text("N/A")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
            } else if isOff {
                Text(.localized("Off"))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
            } else {
                statusPill(isOn: isOn)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func statusPill(isOn: Bool) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isOn ? Color.green : Color.secondary)
                .frame(width: 6, height: 6)
            Text(isOn ? "ON" : "OFF")
                .font(.caption2.weight(.heavy))
                .foregroundStyle(isOn ? Color.green : .secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(isOn ? Color.green.opacity(0.12) : Color.secondary.opacity(0.12), in: Capsule())
    }

    private func refreshSystemSettings() {
        if #available(iOS 16.2, *) {
            systemLiveActivitiesAuthorized = ActivityAuthorizationInfo().areActivitiesEnabled
        } else {
            systemLiveActivitiesAuthorized = false
        }

        Task { @MainActor in
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            pushEnabled = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            lockScreen = settings.lockScreenSetting == .enabled
            notificationCenter = settings.notificationCenterSetting == .enabled
            banners = settings.alertSetting == .enabled
            sounds = settings.soundSetting == .enabled
            badges = settings.badgeSetting == .enabled
            timeSensitive = settings.timeSensitiveSetting == .enabled
            criticalAlerts = settings.criticalAlertSetting == .enabled
            scheduledSummary = settings.scheduledDeliverySetting == .enabled
        }
    }
}
