//
//  AppCustomizationSheet.swift
//  VexSign — Per-App Customization & Privacy Controls
//

import SwiftUI
import NimbleViews
import NimbleExtensions

struct AppCustomizationSheet: View {
    let app: AppInfoPresentable
    @Environment(\.dismiss) private var dismiss

    @ObservedObject private var lock = AppLockManager.shared
    @ObservedObject private var updatePrefs = UpdateMatchingPreferences.shared

    @State private var appName: String = ""
    @State private var isLocked = false
    @State private var isHidden = false
    @State private var isAutoUpdate = false
    @State private var isFavorite = false

    var body: some View {
        NBNavigationView(.localized("App Preferences"), displayMode: .inline) {
            Form {
                headerSection

                identitySection

                securityAndPrivacySection

                updatesAndAutomationSection

                urlSchemeSection
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(.localized("Done")) { dismiss() }
                }
            }
        }
        .onAppear {
            appName = app.name ?? .localized("Application")
            if let uuid = app.uuid {
                isLocked = lock.isAppLocked(uuid)
                isHidden = lock.isAppHidden(uuid)
                isAutoUpdate = updatePrefs.isAutoUpdateAllowed(for: uuid)
                isFavorite = updatePrefs.isFavorite(uuid: uuid)
            }
        }
    }

    private var headerSection: some View {
        Section {
            HStack(spacing: 14) {
                VexAppIconView(app: app, size: 54)

                VStack(alignment: .leading, spacing: 3) {
                    Text(appName)
                        .font(.headline)
                        .lineLimit(1)
                    Text(app.identifier ?? .localized("Unknown Identifier"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let ver = app.version {
                        Text("Version \(ver)")
                            .font(.caption2)
                            .foregroundStyle(Color.userTint)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var identitySection: some View {
        NBSection(.localized("Display Name & Identity")) {
            TextField(.localized("App Name"), text: $appName)

            Button {
                if let uuid = app.uuid, !appName.trimmingCharacters(in: .whitespaces).isEmpty {
                    Storage.shared.updateAppName(uuid: uuid, newName: appName)
                    Toast.success(.localized("App renamed"), systemImage: "pencil")
                }
            } label: {
                Label(.localized("Save Name"), systemImage: "checkmark")
            }
            .disabled(appName.trimmingCharacters(in: .whitespaces).isEmpty)
        } footer: {
            Text(.localized("Changes how the application title is displayed in your library and search."))
        }
    }

    private var securityAndPrivacySection: some View {
        NBSection(.localized("Security & Privacy Vault")) {
            Toggle(isOn: Binding(
                get: { isLocked },
                set: { val in
                    isLocked = val
                    if let uuid = app.uuid {
                        lock.toggleAppLock(uuid)
                    }
                }
            )) {
                Label(.localized("Lock with Face ID"), systemImage: "lock.fill")
            }
            .tint(Color.userTint)

            Toggle(isOn: Binding(
                get: { isHidden },
                set: { val in
                    isHidden = val
                    if let uuid = app.uuid {
                        lock.toggleHideApp(uuid)
                    }
                }
            )) {
                Label(.localized("Hide from Library"), systemImage: "eye.slash.fill")
            }
            .tint(Color.purple)
        } footer: {
            Text(.localized("Specific App Lock requires biometric verification before opening. Hidden apps are concealed in the vault at the bottom of Library."))
        }
    }

    private var updatesAndAutomationSection: some View {
        NBSection(.localized("Updates & Sync")) {
            Toggle(isOn: Binding(
                get: { isFavorite },
                set: { val in
                    isFavorite = val
                    if let uuid = app.uuid {
                        updatePrefs.toggleFavorite(uuid: uuid)
                    }
                }
            )) {
                Label(.localized("Favorite App"), systemImage: "star.fill")
            }
            .tint(Color.yellow)

            Toggle(isOn: Binding(
                get: { isAutoUpdate },
                set: { val in
                    isAutoUpdate = val
                    if let uuid = app.uuid {
                        updatePrefs.toggleAutoUpdate(for: uuid)
                    }
                }
            )) {
                Label(.localized("Automatic Background Updates"), systemImage: "arrow.triangle.2.circlepath")
            }
            .tint(Color.userTint)
        }
    }

    private var urlSchemeSection: some View {
        NBSection(.localized("Fast Launch Deep Link")) {
            if let id = app.identifier {
                let link = "vexsign://launch?bundleId=\(id)"
                HStack {
                    Text(link)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                    Spacer()
                    Button {
                        UIPasteboard.general.string = link
                        Toast.success(.localized("Link copied"), systemImage: "doc.on.clipboard")
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                            .foregroundStyle(Color.userTint)
                    }
                }
            }
        } footer: {
            Text(.localized("Trigger instant launch from Apple Shortcuts, Siri, or third-party launchers."))
        }
    }
}
