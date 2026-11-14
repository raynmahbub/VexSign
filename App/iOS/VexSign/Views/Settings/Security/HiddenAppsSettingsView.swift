//
//  HiddenAppsSettingsView.swift
//  VexSign — Hidden Apps Vault
//

import SwiftUI
import NimbleViews
import NimbleExtensions

struct HiddenAppsSettingsView: View {
    @Environment(\.appContainer) private var appContainer
    @State private var viewModel: HiddenAppsVaultViewModel?

    init(viewModel: HiddenAppsVaultViewModel? = nil) {
        self._viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        Group {
            if let viewModel {
                HiddenAppsSettingsContent(viewModel: viewModel)
            } else {
                ProgressView()
                    .onAppear {
                        let container = appContainer ?? AppContainer.live()
                        viewModel = container.makeHiddenAppsViewModel()
                    }
            }
        }
    }
}

private struct HiddenAppsSettingsContent: View {
    @ObservedObject var viewModel: HiddenAppsVaultViewModel

    var body: some View {
        NBList(.localized("Hidden Apps Vault")) {
            headerSection

            if viewModel.isAuthenticated {
                strictPolicySection
                appsListSection
            } else {
                lockedVaultSection
            }
        }
        .searchable(
            text: $viewModel.searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: .localized("Search apps to hide")
        )
        .onAppear {
            viewModel.reload()
        }
    }

    // MARK: - Header
    private var headerSection: some View {
        Section {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.indigo.opacity(0.15))
                        .frame(width: 48, height: 48)
                    Image(systemName: "eye.slash.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Color.indigo)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(.localized("Hidden Apps Vault"))
                        .font(.headline)
                    Text(String.localized("%lld apps currently hidden from Library.", arguments: viewModel.hiddenCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Locked Vault Prompt
    private var lockedVaultSection: some View {
        Section {
            VStack(spacing: 14) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(Color.indigo)

                Text(.localized("Protected Vault"))
                    .font(.title3.bold())

                Text(.localized("Authenticate to view and manage apps hidden from the main Library and search results."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button {
                    viewModel.requestAccess()
                } label: {
                    HStack {
                        if let bio = viewModel.biometryDisplayName {
                            Image(systemName: bio == "Face ID" ? "faceid" : "touchid")
                        } else {
                            Image(systemName: "lock.open.fill")
                        }
                        Text(.localized("Reveal Hidden Apps"))
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.indigo, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }
    }

    // MARK: - Strict Policy
    private var strictPolicySection: some View {
        NBSection(.localized("Stealth & Security")) {
            Toggle(
                .localized("Strict Hiding Mode"),
                isOn: Binding(
                    get: { viewModel.strictHidingEnabled },
                    set: { viewModel.strictHidingEnabled = $0 }
                )
            )
            .tint(Color.indigo)
        } footer: {
            Text(.localized("Strict Hiding completely excludes hidden apps from search, widgets, and export suggestions until this vault is unlocked."))
        }
    }

    // MARK: - Apps List
    private var appsListSection: some View {
        NBSection(.localized("Manage Library Visibility")) {
            if viewModel.filteredApps.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text(.localized("No Apps Found"))
                        .font(.subheadline.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                ForEach(viewModel.filteredApps) { app in
                    let isHidden = viewModel.isAppHidden(app.uuid)

                    HStack(spacing: 12) {
                        VexAppIconView(bundleURL: app.bundleURL, size: 40)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            Text(app.identifier)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        Toggle("", isOn: Binding(
                            get: { isHidden },
                            set: { _ in
                                NBHaptic.tap()
                                viewModel.toggleHideApp(app.uuid)
                            }
                        ))
                        .labelsHidden()
                        .tint(Color.indigo)
                    }
                    .padding(.vertical, 2)
                }
            }
        } footer: {
            Text(.localized("Toggle an app ON to hide it from the main Library tab. You can always unhide or launch hidden apps from this secure vault."))
        }
    }
}
