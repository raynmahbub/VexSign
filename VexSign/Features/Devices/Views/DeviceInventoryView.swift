//
//  DeviceInventoryView.swift
//  VexSign
//
//  Real, library-app-scoped device inventory. Every row comes from a read-only
//  query against the selected device over the reviewed pairing session. A row
//  that cannot be read stays "No comparable device report" instead of becoming
//  a negative installation claim.
//

import SwiftUI
import NimbleExtensions

struct DeviceInventoryView: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @StateObject private var model = DeviceInventoryModel()
    let expectedIdentifier: String

    var body: some View {
        Form {
            Section {
                Text(.localized("VexSign asks the selected device about the bundle identifiers in this library, one at a time. This is read-only CoreDevice inventory evidence, not a full application list, a private-container read, or proof that VexSign installed an app."))
                    .font(.footnote)
            }

            Section {
                Button {
                    model.refresh(apps: workspace.snapshot.apps)
                } label: {
                    Label(.localized("Read installed apps from selected device"), systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(!canRefresh)
                if model.isRefreshing {
                    HStack {
                        ProgressView()
                        Text(model.stageTitle ?? .localized("Reading device inventory…"))
                            .font(.caption)
                    }
                    Button(.localized("Cancel inventory read"), role: .cancel) { model.cancel() }
                }
                if let refreshedAt = model.refreshedAt {
                    Text(String.localized("Last successful read: %@", arguments: Self.timeFormatter.string(from: refreshedAt)))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if let message = model.message {
                    Text(message).font(.caption).textSelection(.enabled)
                }
            } header: {
                Text(.localized("Read-only inventory"))
            } footer: {
                Text(.localized("Requires a verified device, an unchanged pairing record, explicit device-service consent and the active local transport. Pairing itself never grants inventory access."))
                    .font(.caption2)
            }

            if !model.rows.isEmpty {
                Section {
                    ForEach(model.rows) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(row.name).font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(row.state.title).font(.caption).foregroundStyle(color(for: row.state))
                            }
                            Text(row.bundleIdentifier)
                                .font(.caption2.monospaced()).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Text(String.localized("Library: %@ (%@)", arguments: row.expectedVersion ?? "?", row.expectedBuild ?? "?"))
                                .font(.caption2)
                            if row.state != .unreported {
                                Text(String.localized("Device: %@ (%@)", arguments: row.deviceVersion ?? "?", row.deviceBuild ?? "?"))
                                    .font(.caption2)
                            }
                            Text(row.detail).font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text(.localized("Library apps on this device"))
                }
            }
        }
        .navigationTitle(.localized("Device inventory"))
        .onDisappear { model.clear() }
    }

    private var canRefresh: Bool {
        !model.isRefreshing
            && PairingBridge.protocolConsent
            && PairingBridge.canQuery(PairingBridge.inspectPairingRecord(), expectedIdentifier: expectedIdentifier)
            && !workspace.snapshot.apps.isEmpty
    }

    private func color(for state: DeviceInstalledAppState) -> Color {
        switch state {
        case .current: .green
        case .otherVersion: .orange
        case .unreported: .secondary
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}
