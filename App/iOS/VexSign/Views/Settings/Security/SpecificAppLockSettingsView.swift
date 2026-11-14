//
//  SpecificAppLockSettingsView.swift
//  VexSign — Specific App Biometric Lock Rules
//

import SwiftUI
import NimbleViews
import NimbleExtensions

struct SpecificAppLockSettingsView: View {
    @Environment(\.appContainer) private var appContainer
    @State private var viewModel: SpecificAppLockViewModel?

    init(viewModel: SpecificAppLockViewModel? = nil) {
        self._viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        Group {
            if let viewModel {
                SpecificAppLockContent(viewModel: viewModel)
            } else {
                ProgressView()
                    .onAppear {
                        let container = appContainer ?? AppContainer.live()
                        viewModel = container.makeSpecificAppLockViewModel()
                    }
            }
        }
    }
}

private struct SpecificAppLockContent: View {
    @ObservedObject var viewModel: SpecificAppLockViewModel

    var body: some View {
        NBList(.localized("Lock Specific Apps")) {
            headerSection
            appsListSection
        }
        .searchable(
            text: $viewModel.searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: .localized("Search apps")
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
                        .fill(Color.blue.opacity(0.15))
                        .frame(width: 48, height: 48)
                    Image(systemName: "lock.app.dashed")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Color.blue)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(.localized("Per-App Authentication"))
                        .font(.headline)
                    Text(String.localized("%lld apps currently require authentication.", arguments: viewModel.lockedCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Apps List
    private var appsListSection: some View {
        NBSection(.localized("Library Applications")) {
            if viewModel.filteredApps.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text(.localized("No Apps Found"))
                        .font(.subheadline.weight(.semibold))
                    Text(.localized("Import or sign apps to configure individual app locks."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                ForEach(viewModel.filteredApps) { app in
                    let isLocked = viewModel.isAppLocked(app.uuid)

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
                            get: { isLocked },
                            set: { _ in
                                NBHaptic.tap()
                                viewModel.toggleAppLock(app.uuid)
                            }
                        ))
                        .labelsHidden()
                        .tint(Color.userTint)
                    }
                    .padding(.vertical, 2)
                }
            }
        } footer: {
            Text(.localized("Locked apps require Face ID, Touch ID, or device passcode before they can be opened, signed, installed, or exported from Library."))
        }
    }
}
