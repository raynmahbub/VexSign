//
//  LibraryView+BatchActions.swift
//  VexSign
//
//  Selection bar, batch operations, reordering, and bulk deletion for LibraryView.
//

import SwiftUI
import NimbleExtensions

extension LibraryView {
    // MARK: Selection Action Bar
    var selectionActionBar: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text(String.localized("%lld selected", arguments: _selectedAppUUIDs.count))
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            WorkspaceActionGroup { selectionActionButtons }
        }
        .padding(.horizontal)
        .padding(.vertical, Theme.Spacing.medium)
        .background(Theme.card)
        .overlay(alignment: .top) { Divider() }
        .reportsBottomBarHeight()
    }

    @ViewBuilder
    private var selectionActionButtons: some View {
        let selection = selectedApps()
        let canSign = selection.contains { !$0.isSigned }
        let canInstall = !selection.isEmpty && selection.allSatisfy { $0.isSigned }
        if canInstall {
            _actionButton(.localized("Install"), systemImage: "square.and.arrow.down") { _startBatch(.install) }
        } else {
            _actionButton(.localized("Sign"), systemImage: "signature", isDisabled: !canSign) { _startBatch(.sign) }
        }
        _actionButton(.localized("Export"), systemImage: "square.and.arrow.up") {
            let apps = selectedApps()
            _selectedAppUUIDs.removeAll()
            _editMode = .inactive
            for app in apps { InstallQueue.shared.enqueue(app, exporting: true) }
        }
        Menu {
            if !canInstall {
                Button(.localized("Sign & Install"), systemImage: "square.and.arrow.down.on.square") {
                    _startBatch(.signAndInstall)
                }
                .disabled(!canSign || selection.isEmpty)
            }
            Button(.localized("Delete selected apps"), systemImage: "trash", role: .destructive) {
                _showDeleteConfirmation = true
            }
        } label: {
            Label(.localized("More"), systemImage: "ellipsis.circle")
                .font(.subheadline.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .disabled(selection.isEmpty)
        .accessibilityLabel(Text(.localized("More actions for selected apps")))
    }

    @ViewBuilder
    private func _actionButton(
        _ title: String,
        systemImage: String,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .disabled(isDisabled || _selectedAppUUIDs.isEmpty)
    }
}

// MARK: - Extension: Batch
extension LibraryView {
    struct BatchRequest: Identifiable {
        let id = UUID()
        let apps: [AppInfoPresentable]
        let mode: BatchJobRunner.Mode
    }

    func selectedApps() -> [AppInfoPresentable] {
        getAllApps().filter { app in
            guard let uuid = app.uuid else { return false }
            return _selectedAppUUIDs.contains(uuid)
        }
    }

    func _beginSelection(with app: AppInfoPresentable) {
        guard let uuid = app.uuid else { return }

        withAnimation {
            _editMode = .active
            _selectedAppUUIDs = [uuid]
        }
    }

    private func _startBatch(_ mode: BatchJobRunner.Mode) {
        let apps = selectedApps()
        guard !apps.isEmpty else { return }

        _batchRequest = BatchRequest(apps: apps, mode: mode)
        _selectedAppUUIDs.removeAll()
        _editMode = .inactive
    }
}

// MARK: - Extension: Reorder
extension LibraryView {
    func _moveSignedApps(from source: IndexSet, to destination: Int) {
        var apps = filteredSignedApps
        apps.move(fromOffsets: source, toOffset: destination)

        for (index, app) in apps.enumerated() {
            app.sortIndex = Int32(index)
        }
        Storage.shared.saveContext()
    }

    func _moveImportedApps(from source: IndexSet, to destination: Int) {
        var apps = filteredImportedApps
        apps.move(fromOffsets: source, toOffset: destination)

        for (index, app) in apps.enumerated() {
            app.sortIndex = Int32(index)
        }
        Storage.shared.saveContext()
    }
}

// MARK: - Extension: Bulk Delete
extension LibraryView {
    func bulkDeleteSelectedApps() {
        var failed = 0
        for app in selectedApps() where !Storage.shared.deleteApp(for: app) {
            failed += 1
        }

        if failed > 0 {
            Toast.error(
                String.localized("Couldn't delete %lld app(s). They are still in the Library; try again.", arguments: Int64(failed)),
                duration: .sticky
            )
        }

        _selectedAppUUIDs.removeAll()
        _editMode = .inactive
    }

    func getAllApps() -> [AppInfoPresentable] {
        var allApps: [AppInfoPresentable] = []

        if shouldShowSignedSection {
            allApps.append(contentsOf: filteredSignedApps)
        }

        if shouldShowImportedSection {
            allApps.append(contentsOf: filteredImportedApps)
        }

        return allApps
    }

    var areAllAppsSelected: Bool {
        let allApps = getAllApps()
        let allUUIDs = Set(allApps.compactMap { $0.uuid })
        return !allUUIDs.isEmpty && _selectedAppUUIDs == allUUIDs
    }

    func selectAllApps() {
        if areAllAppsSelected {
            _selectedAppUUIDs.removeAll()
        } else {
            let allApps = getAllApps()
            _selectedAppUUIDs = Set(allApps.compactMap { $0.uuid })
        }
    }
}
