//
//  FavoritesAndAutoUpdatesSettingsView.swift
//  VexSign — Favorites and Auto Updates Settings
//

import SwiftUI
import NimbleViews
import NimbleExtensions

struct FavoritesAndAutoUpdatesSettingsView: View {
    @Environment(\.appContainer) private var appContainer
    @State private var viewModel: FavoritesAutoUpdatesViewModel?

    init(viewModel: FavoritesAutoUpdatesViewModel? = nil) {
        self._viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        Group {
            if let viewModel {
                FavoritesAndAutoUpdatesContent(viewModel: viewModel)
            } else {
                ProgressView()
                    .onAppear {
                        let container = appContainer ?? AppContainer.live()
                        viewModel = container.makeFavoritesAutoUpdatesViewModel()
                    }
            }
        }
    }
}

private struct FavoritesAndAutoUpdatesContent: View {
    @ObservedObject var viewModel: FavoritesAutoUpdatesViewModel
    @ObservedObject private var prefs = UpdateMatchingPreferences.shared
    @State private var searchText = ""
    @State private var filterMode: FilterOption = .all

    enum FilterOption: String, CaseIterable, Identifiable {
        case all = "All"
        case favorites = "Favorites"
        case autoUpdate = "Auto-Update"
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return .localized("All")
            case .favorites: return .localized("Favorites")
            case .autoUpdate: return .localized("Auto-Update")
            }
        }
    }

    private var filteredApps: [AppPrivacyItem] {
        viewModel.apps.filter { app in
            let nameMatch = searchText.isEmpty || app.name.localizedCaseInsensitiveContains(searchText)
            guard nameMatch else { return false }

            switch filterMode {
            case .all:
                return true
            case .favorites:
                return prefs.isFavorite(uuid: app.uuid)
            case .autoUpdate:
                return prefs.isAutoUpdateAllowed(for: app.uuid)
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
        .onAppear {
            viewModel.refresh()
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
                Text(.localized("Global Default")).tag("Global Default")
                Text("VexSign (Dist)").tag("VexSign (Dist)")
                ForEach(viewModel.certificateOptions) { option in
                    Text(option.displayName).tag(option.tagName)
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
                    Text(opt.title).tag(opt)
                }
            }
            .pickerStyle(.segmented)
            .padding(.vertical, 4)

            if viewModel.apps.isEmpty {
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
                ForEach(filteredApps) { app in
                    let isFav = prefs.isFavorite(uuid: app.uuid)
                    let isAuto = prefs.isAutoUpdateAllowed(for: app.uuid)

                    HStack(spacing: 12) {
                        VexAppIconView(bundleURL: app.bundleURL, size: 40)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            Text(app.version)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button {
                            NBHaptic.tap()
                            prefs.toggleFavorite(uuid: app.uuid)
                        } label: {
                            Image(systemName: isFav ? "star.fill" : "star")
                                .font(.system(size: 18))
                                .foregroundStyle(isFav ? Color.yellow : Color.secondary.opacity(0.5))
                                .padding(6)
                        }
                        .buttonStyle(.plain)

                        Button {
                            NBHaptic.tap()
                            prefs.toggleAutoUpdate(for: app.uuid, allUUIDs: Set(viewModel.apps.map(\.uuid)))
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
        } footer: {
            Text(.localized("Tap the star to favorite an app. Tap the circular arrow icon to enable or disable automatic updates for that specific app."))
        }
    }
}
