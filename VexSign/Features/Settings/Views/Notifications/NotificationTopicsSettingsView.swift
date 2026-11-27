//
//  NotificationTopicsSettingsView.swift
//  VexSign
//
//  Real, persisted switches for notifications VexSign posts itself, plus the
//  history the service records after a successful delivery. The system's own
//  authorization remains in iOS Settings; when it is denied this screen says
//  so instead of leaving switches that appear to work but cannot deliver.
//

import SwiftUI
import NimbleViews
import NimbleExtensions

struct NotificationTopicsSettingsView: View {
    @ObservedObject private var service = VexSignNotificationService.shared
    @ObservedObject private var preferences = VexSignNotificationService.shared.preferences
    @ObservedObject private var history = VexSignNotificationService.shared.history
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmation = false

    @MainActor
    init() {
        let service = VexSignNotificationService.shared
        _service = ObservedObject(wrappedValue: service)
        _preferences = ObservedObject(wrappedValue: service.preferences)
        _history = ObservedObject(wrappedValue: service.history)
    }

    private var systemDenied: Bool {
        service.authorizationStatus == .denied
    }

    var body: some View {
        NBList(.localized("Notification Types")) {
            Section {
                if systemDenied {
                    Text(.localized("Notifications are turned off for VexSign in iOS Settings. These switches are saved, but iOS will not deliver any banner until you allow notifications."))
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button {
                        openSystemSettings()
                    } label: {
                        Label(.localized("Open iOS Settings"), systemImage: "arrow.up.right.circle")
                    }
                } else if service.authorizationStatus == .notDetermined {
                    Button {
                        Task { @MainActor in await service.requestAuthorization() }
                    } label: {
                        Label(.localized("Allow Notifications"), systemImage: "bell.badge")
                    }
                }
            } footer: {
                Text(.localized("Local notifications can appear while VexSign is closed, but they cannot run signing, installation or update logic. Tap a banner to open the relevant screen."))
            }

            Section {
                ForEach(NotificationTopic.allCases, id: \.self) { topic in
                    Toggle(isOn: Binding(
                        get: { preferences.isEnabled(topic) },
                        set: { preferences.set(topic, enabled: $0) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(topic.label)
                            Text(topic.detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text(.localized("POST FROM VEXSIGN"))
            }

            Section {
                ForEach(ExpiryMilestone.allCases, id: \.self) { milestone in
                    Toggle(milestone.title, isOn: Binding(
                        get: { preferences.isExpiryMilestoneEnabled(milestone) },
                        set: { preferences.setExpiryMilestone(milestone, enabled: $0) }
                    ))
                }
            } header: {
                Text(.localized("EXPIRY REMINDERS"))
            } footer: {
                Text(.localized("Reminders use the expiration date stored with each imported identity. A missing date stays Unknown and never produces a reminder."))
            }

            Section {
                if history.entries.isEmpty {
                    Text(.localized("No notifications delivered yet."))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(history.entries.suffix(10)) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.title).font(.subheadline.weight(.semibold))
                            Text(entry.body).font(.caption)
                            Text(entry.deliveredAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button(.localized("Clear History"), role: .destructive) { confirmation = true }
                }
            } header: {
                Text(.localized("RECENT DELIVERIES"))
            }
        }
        .onAppear { service.refreshAuthorizationStatus() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { service.refreshAuthorizationStatus() }
        }
        .confirmationDialog(.localized("Clear notification history?"), isPresented: $confirmation) {
            Button(.localized("Clear History"), role: .destructive) { history.clear() }
            Button(.localized("Cancel"), role: .cancel) {}
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.open(url)
    }
}
