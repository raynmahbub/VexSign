//
//  FavoritesAndAutoUpdatesSettingsView.swift
//  VexSign — Favorites and Auto Updates Settings
//

import SwiftUI
import CoreData
import NimbleViews
import NimbleExtensions

struct FavoritesAndAutoUpdatesSettingsView: View {
    @ObservedObject private var prefs = UpdateMatchingPreferences.shared
    @State private var searchText = ""
    @State private var filterMode: FilterOption = .all

    @FetchRequest(
        entity: Signed.entity(),
        sortDescriptors: [NSSortDescriptor(keyPath: \Signed.name, ascending: true)],
        animation: .snappy
    ) private var signedApps: FetchedResults<Signed>

    @FetchRequest(
        entity: Imported.entity(),
        sortDescriptors: [NSSortDescriptor(keyPath: \Imported.name, ascending: true)],
        animation: .snappy
    ) private var importedApps: FetchedResults<Imported>

    private let certificates = Storage.shared.getAllCertificates()

    enum FilterOption: String, CaseIterable, Identifiable {
        case all = "All"
        case favorites = "Favorites"
        case autoUpdate = "Auto-Update"
        var id: String { rawValue }
    }

    private var allApps: [AppInfoPresentable] {
        var result: [AppInfoPresentable] = []
        result.append(contentsOf: signedApps.map { $0 as AppInfoPresentable })
        result.append(contentsOf: importedApps.map { $0 as AppInfoPresentable })
        return result
    }

    private var filteredApps: [AppInfoPresentable] {
        allApps.filter { app in
            guard let uuid = app.uuid else { return false }
            let nameMatch = searchText.isEmpty || (app.name?.localizedCaseInsensitiveContains(searchText) ?? false)
            guard nameMatch else { return false }

            switch filterMode {
            case .all:
                return true
            case .favorites:
                return prefs.isFavorite(uuid: uuid)
            case .autoUpdate:
                return prefs.isAutoUpdateAllowed(for: uuid)
            }
        }
    }

    var body: some View {
        NBList(.localized("Favorites & Auto Updates")) {
            headerOverviewSection

            matchingModeSection

            autoUpdateCertSection

            automationSettingsSection

            favoriteAppsManagementSection
        }
    }

    // MARK: - Overview
    private var headerOverviewSection: some View {
        Section {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.yellow.opacity(0.15))
                        .frame(width: 48, height: 48)
                    Image(systemName: "star.circle.fill")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(Color.yellow)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(.localized("Favorites & Auto Updates"))
                        .font(.headline)
                    Text(.localized("Configure automated background update signing and manage priority apps."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Matching Mode
    private var matchingModeSection: some View {
        NBSection(.localized("Matching Mode")) {
            Picker(.localized("Mode"), selection: $prefs.matchingMode) {
                ForEach(UpdateMatchingMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.menu)

            Text(prefs.matchingMode.localizedDescription)
                .font(.footnote)
                .foregroundStyle(.secondary)
        } footer: {
            Text(.localized("When set to “Favorites Only”, background update checks and auto-signing will restrict themselves exclusively to apps you have starred."))
        }
    }

    // MARK: - Auto Update Certificate
    private var autoUpdateCertSection: some View {
        NBSection(.localized("Auto Update Certificate")) {
            Picker(.localized("Signing Certificate"), selection: $prefs.autoUpdateCertificate) {
                Text("Global Default").tag("Global Default")
                Text("VexSign (Dist)").tag("VexSign (Dist)")
                ForEach(certificates, id: \.uuid) { cert in
                    let name = cert.nickname ?? Storage.shared.getProvisionFileDecoded(for: cert)?.Name ?? "Certificate"
                    Text(name).tag(name)
                }
            }
            .pickerStyle(.menu)
        } footer: {
            Text(.localized("The certificate specified here will be automatically applied whenever an update is fetched and re-signed in the background."))
        }
    }

    // MARK: - Automation Settings
    private var automationSettingsSection: some View {
        NBSection(.localized("Automation Settings")) {
            Toggle(.localized("Enable Background Auto Updates"), isOn: $prefs.isAutoUpdateEnabled)
                .tint(Color.userTint)

            Toggle(.localized("Wi-Fi Only"), isOn: $prefs.autoUpdateWifiOnly)
                .tint(Color.userTint)

            Toggle(.localized("Notify on Update Complete"), isOn: $prefs.notifyOnAutoUpdate)
                .tint(Color.userTint)

            Toggle(.localized("Auto-Install After Signing"), isOn: $prefs.autoInstallAfterUpdate)
                .tint(Color.userTint)
        } footer: {
            Text(.localized("Downloaded IPAs are signed with your chosen certificate. When automatic install queueing is enabled, eligible signed updates enter the install queue and begin when VexSign is active; iOS may still require confirmation."))
        }
    }

    // MARK: - Favorite & Auto Update Apps
    private var favoriteAppsManagementSection: some View {
        NBSection(.localized("Manage Apps")) {
            Picker(.localized("Filter"), selection: $filterMode) {
                ForEach(FilterOption.allCases) { opt in
                    Text(opt.rawValue).tag(opt)
                }
            }
            .pickerStyle(.segmented)
            .padding(.vertical, 4)

            if allApps.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.up.slash")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text(.localized("No Apps in Library"))
                        .font(.subheadline.weight(.semibold))
                    Text(.localized("Import or sign an app to configure individual auto-update preferences."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            } else if filteredApps.isEmpty {
                Text(.localized("No apps match the selected filter."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                ForEach(filteredApps, id: \.uuid) { app in
                    if let uuid = app.uuid {
                        let isFav = prefs.isFavorite(uuid: uuid)
                        let isAuto = prefs.isAutoUpdateAllowed(for: uuid)

                        HStack(spacing: 12) {
                            FRAppIconView(app: app, size: 40)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.name ?? .localized("Unknown"))
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                Text(app.version ?? "1.0")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            // Favorite toggle button
                            Button {
                                NBHaptic.tap()
                                prefs.toggleFavorite(uuid: uuid)
                            } label: {
                                Image(systemName: isFav ? "star.fill" : "star")
                                    .font(.system(size: 18))
                                    .foregroundStyle(isFav ? Color.yellow : Color.secondary.opacity(0.5))
                                    .padding(6)
                            }
                            .buttonStyle(.plain)

                            // Auto update toggle button
                            Button {
                                NBHaptic.tap()
                                prefs.toggleAutoUpdate(for: uuid, allUUIDs: Set(allApps.compactMap { $0.uuid }))
                            } label: {
                                Image(systemName: isAuto ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.triangle.2.circlepath.circle")
                                    .font(.system(size: 20))
                                    .foregroundStyle(isAuto ? Color.userTint : Color.secondary.opacity(0.4))
                                    .padding(6)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        } footer: {
            Text(.localized("Tap the star to favorite an app. Tap the circular arrow icon to enable or disable automatic updates for that specific app."))
        }
    }
}
