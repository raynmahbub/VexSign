//
//  ProvisioningFlowSupportingViews.swift
//  VexSign
//
//  The cards and pickers the provisioning wizard composes.
//

import SwiftUI
import NimbleExtensions

// MARK: - Supporting Views

struct AppSelectionCard: View {
    @EnvironmentObject private var services: AppContainer
    let app: AppInfoPresentable
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let iconName = app.icon, let data = services.files.iconData(named: iconName), let uiImage = UIImage(data: data) { // try? ok: optional icon, falls back to placeholder
                Image(uiImage: uiImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                    .cornerRadius(12)
            } else {
                Image(systemName: "app.fill")
                    .font(.title)
                    .frame(width: 56, height: 56)
                    .background(Color.accentColor.opacity(0.2))
                    .cornerRadius(12)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(app.name ?? .localized("Unknown"))
                    .font(.headline)
                Text(app.identifier ?? .localized("Unknown"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(app.version ?? "")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.title2)
            }
        }
        .padding()
        .background(Color(uiColor: .quaternarySystemFill))
        .cornerRadius(14)
    }
}

struct ReviewCard: View {
    let appName: String
    let bundleIdentifier: String
    let deviceUDID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ReviewRow(label: .localized("App"), value: appName)
            ReviewRow(label: .localized("Bundle ID"), value: bundleIdentifier, monospaced: true)
            ReviewRow(label: .localized("Device UDID"), value: deviceUDID, monospaced: true)
            ReviewRow(label: .localized("Certificate"), value: .localized("Development (auto-generated)"))
            ReviewRow(label: .localized("Profile"), value: .localized("iOS Development (auto-generated)"))
        }
        .padding()
        .background(Color(uiColor: .quaternarySystemFill))
        .cornerRadius(14)
    }
}

struct ReviewRow: View {
    let label: String
    let value: String
    var monospaced: Bool = false

    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(monospaced ? .system(.subheadline, design: .monospaced) : .subheadline)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

struct AppPickerView: View {
    @EnvironmentObject var services: AppContainer
    @Binding var selectedApp: AppInfoPresentable?
    let signedOnly: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var allApps: [AppInfoPresentable] = []

    var body: some View {
        NavigationStack {
            List {
                ForEach(allApps, id: \.uuid) { app in
                    Button {
                        selectedApp = app
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(app.name ?? .localized("Unknown"))
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text(app.identifier ?? .localized("Unknown"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if selectedApp?.uuid == app.uuid {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                }
            }
            .dismissableKeyboard()
            .task {
                allApps = services.workspace.snapshot.apps.filter { !signedOnly || $0.isSigned }
            }
            .navigationTitle(.localized("Select App"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(.localized("Cancel")) { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }
}

// MARK: - ProvisioningStep

enum ProvisioningStep: Int, CaseIterable {
    case selectApp = 1
    case selectDevice = 2
    case review = 3
    case provisioning = 4
    case complete = 5

    var order: Int { rawValue }

    var title: String {
        switch self {
        case .selectApp: return .localized("1. Select App")
        case .selectDevice: return .localized("2. Select Device")
        case .review: return .localized("3. Review")
        case .provisioning: return .localized("4. Provisioning")
        case .complete: return .localized("5. Complete")
        }
    }
}