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
    @State private var pushEnabled: Bool = true
    @State private var lockScreen: Bool = true
    @State private var notificationCenter: Bool = true
    @State private var banners: Bool = true
    @State private var sounds: Bool = true
    @State private var badges: Bool = true
    @State private var timeSensitive: Bool = true
    @State private var criticalAlerts: Bool = false
    @State private var scheduledSummary: Bool = false

    @AppStorage("VexSign.liveActivitiesEnabled") private var liveActivitiesEnabled: Bool = true
    @AppStorage("VexSign.dynamicIslandEnabled") private var dynamicIslandEnabled: Bool = true

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
                        Text(.localized("Push Notifications"))
                            .font(.subheadline.weight(.semibold))
                        Text(pushEnabled ? .localized("Enabled") : .localized("Disabled"))
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
                deliveryRow(icon: "exclamationmark.triangle.fill", title: .localized("Critical Alerts"), isOn: criticalAlerts, isNA: true)
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
                        Text(.localized("Live Activities"))
                            .font(.subheadline.weight(.semibold))
                        Text(liveActivitiesEnabled ? .localized("Enabled") : .localized("Disabled"))
                            .font(.caption2)
                            .foregroundStyle(liveActivitiesEnabled ? .purple : .secondary)
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
                        Text(.localized("Dynamic Island"))
                            .font(.subheadline.weight(.semibold))
                        Text(dynamicIslandEnabled ? .localized("Supported") : .localized("Disabled"))
                            .font(.caption2)
                            .foregroundStyle(dynamicIslandEnabled ? .purple : .secondary)
                    }

                    Spacer()

                    Toggle("", isOn: $dynamicIslandEnabled)
                        .labelsHidden()
                        .tint(Color.green)
                }
                .padding(.vertical, 2)
            } footer: {
                Text(.localized("Live Activities require iOS 16.1+. Dynamic Island requires iPhone 14 Pro or newer."))
            }
        }
        .onAppear {
            checkSystemNotificationSettings()
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

    private func checkSystemNotificationSettings() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                self.pushEnabled = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
                self.lockScreen = settings.lockScreenSetting == .enabled
                self.notificationCenter = settings.notificationCenterSetting == .enabled
                self.banners = settings.alertSetting == .enabled
                self.sounds = settings.soundSetting == .enabled
                self.badges = settings.badgeSetting == .enabled
                self.timeSensitive = settings.timeSensitiveSetting == .enabled
                self.criticalAlerts = settings.criticalAlertSetting == .enabled
                self.scheduledSummary = settings.scheduledDeliverySetting == .enabled
            }
        }
    }
}
