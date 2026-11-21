//
//  BackupView.swift
//  VexSign
//
//  Created by VexSign Team
//

import SwiftUI
import NimbleViews
import NimbleExtensions

// MARK: - View
@MainActor
struct BackupView: View {
    /// A backup staged before this screen existed (a file handed over by Files,
    /// AirDrop or a share sheet). It is inspected on appear through the same
    /// password/preview path as the picker, never restored automatically.
    private let initialBackup: URL?

    init(initialBackup: URL? = nil) {
        self.initialBackup = initialBackup
    }

    @EnvironmentObject private var services: AppContainer
    @State private var operation: Task<Void, Never>?
    @State private var presentationState = BackupPresentationState()
    @State private var openedArchiveID: UUID?
    @State private var openedArchiveGeneration: UUID?
    @State private var _isWorking = false
    @State private var _showRestorePassword = false
    @State private var _password = ""
    @State private var _pendingImport: (url: URL, generation: UUID)?
    @State private var _archive: BackupArchiveSnapshot?
    @State private var _showExportPicker = false
    @State private var _exportPickerGeneration: UUID?
    @State private var _pendingExport: (generation: UUID, components: BackupComponents, password: String)?
    @State private var _showLegacyWarning = false
    @State private var _adoptedSharedBackup = false

    // MARK: Body
    var body: some View {
        NBList(.localized("Backup & Restore")) {
            Section {
                Button {
                    guard let attempt = _beginOperation() else { return }
                    _pendingExport = nil
                    _exportPickerGeneration = attempt
                    _showExportPicker = true
                } label: {
                    Label(.localized("Create Backup"), systemImage: "square.and.arrow.up")
                }
            } footer: {
                Text(.localized("Saves selected components, including signed and imported app bundles. Backups use streaming encryption with an 8 GiB safe extraction limit; installed app data is not included."))
            }

            Section {
                Button {
                    guard let attempt = _beginOperation() else { return }
                    DocumentPicker.open([.vexBackup], folder: .backups) { urls in
                        guard presentationState.isCurrent(attempt), let url = urls.first else { return }
                        _pendingImport = (url, attempt)
                        _password = ""
                        _inspectBackup(url, attempt: attempt)
                    }
                } label: {
                    Label(.localized("Restore from Backup"), systemImage: "square.and.arrow.down")
                }
            } footer: {
                Text(.localized("Open a backup file, then pick what comes back. Backups made without a password are encrypted for this device and cannot be restored on another one."))
            }
        }
        .disabled(_isWorking)
        .animation(.easeInOut(duration: 0.2), value: _isWorking)
        .overlay { _workingOverlay }
        .sheet(isPresented: $_showExportPicker, onDismiss: _runExport) {
            let offerGeneration = _exportPickerGeneration
            let available = services.backups.availableComponents()
            BackupComponentsView(
                title: .localized("Create Backup"),
                confirmTitle: .localized("Create"),
                available: available.components,
                counts: available.counts,
                footer: .localized("Choose what to include in this backup."),
                passwordFooter: .localized("Every backup is encrypted. With a password it can be restored on another device; without one it stays readable only on this one. A backup that includes certificates needs a password of at least %lld characters.", arguments: Int64(BackupPolicy.minimumPasswordLength)),
                enforcesPasswordForCertificates: true,
                onConfirm: { components, password in
                    guard let attempt = offerGeneration, _exportPickerGeneration == attempt,
                          presentationState.isCurrent(attempt) else { return }
                    _pendingExport = (attempt, components, password)
                }
            )
        }
        .sheet(item: $_archive, onDismiss: _presentRestoreComplete) { archive in
            BackupComponentsView(
                title: .localized("Restore from Backup"),
                confirmTitle: .localized("Restore"),
                available: archive.contents,
                counts: _archiveCounts(archive),
                detail: _archiveDetail(archive),
                footer: .localized("Nothing is deleted. Anything already here is skipped."),
                onConfirm: { components, _ in _restore(archive, components: components) }
            )
        }
        .alert(.localized("Unencrypted backup"), isPresented: $_showLegacyWarning, presenting: _pendingImport) { pending in
            Button(.localized("Cancel"), role: .cancel) { _cancelImport(for: pending.generation) }
            Button(.localized("Restore Anyway")) { _openBackup(for: pending.generation) }
        } message: { _ in
            Text(.localized("This file was made by an older version of VexSign and is not encrypted. If it includes certificates, it holds private keys in the clear. Delete it once you have restored what you need."))
        }
        .alert(.localized("Backup Password"), isPresented: $_showRestorePassword, presenting: _pendingImport) { pending in
            SecureField(.localized("Password"), text: $_password)
            Button(.localized("Cancel"), role: .cancel) { _cancelImport(for: pending.generation) }
            Button(.localized("Continue")) { _openBackup(for: pending.generation) }
        } message: { _ in
            Text(.localized("Enter the password this backup was encrypted with."))
        }
        .onAppear {
            presentationState.appear()
            _adoptSharedBackup()
        }
        .onDisappear {
            // Retire the generation before dismissing sheets/alerts: their
            // queued callbacks must not start work in a later appearance.
            presentationState.disappear()
            operation?.cancel()
            operation = nil
            _isWorking = false
            _password = ""; _pendingImport = nil; _pendingExport = nil
            _exportPickerGeneration = nil
            _showRestorePassword = false; _showLegacyWarning = false
            _showExportPicker = false; _archive = nil
            _releaseArchive()
        }
    }

    private func _beginOperation() -> UUID? {
        guard !_isWorking, let attempt = presentationState.beginOperation() else { return nil }
        operation?.cancel()
        operation = nil
        return attempt
    }

    private func _finishOperation(_ attempt: UUID) {
        guard presentationState.isCurrent(attempt) else { return }
        _isWorking = false
        operation = nil
    }

    /// Adopt the handed-over file exactly once per appearance. A missing file is
    /// reported rather than silently ignored: the temporary copy is the app's own
    /// and should not vanish, so its absence means something else cleaned up.
    private func _adoptSharedBackup() {
        guard let url = initialBackup, !_adoptedSharedBackup else { return }
        _adoptedSharedBackup = true
        guard !_isWorking, let attempt = _beginOperation() else { return }
        _pendingImport = (url, attempt)
        _password = ""
        _inspectBackup(url, attempt: attempt)
    }

    private func _inspectBackup(_ url: URL, attempt: UUID) {
        guard presentationState.isCurrent(attempt) else { return }
        _isWorking = true
        operation = Task { @MainActor in
            defer { _finishOperation(attempt) }
            do {
                let protection = try await services.backups.protection(of: url)
                guard !Task.isCancelled, presentationState.isCurrent(attempt) else { return }
                // Opening a device-only archive replaces this task. Finish the
                // inspection first so its defer cannot clobber the new task.
                _finishOperation(attempt)
                switch protection {
                case .legacyPlaintext: _showLegacyWarning = true
                case .password: _showRestorePassword = true
                case .deviceOnly: _openBackup(for: attempt)
                }
            } catch {
                if presentationState.isCurrent(attempt), !(error is CancellationError) { Toast.error(error.localizedDescription) }
            }
        }
    }

    private func _releaseArchive() {
        guard let id = openedArchiveID else { return }
        services.backups.release(archiveID: id)
        openedArchiveID = nil
        openedArchiveGeneration = nil
    }

    private func _restore(_ archive: BackupArchiveSnapshot, components: BackupComponents) {
        guard openedArchiveID == archive.id,
              let archiveGeneration = openedArchiveGeneration,
              presentationState.isCurrent(archiveGeneration),
              let attempt = _beginOperation() else { return }
        // The preview keeps its old generation, so a second Confirm cannot
        // admit another restore while this one completes or its alert waits.
        _isWorking = true
        operation = Task { @MainActor in
            defer {
                services.backups.release(archiveID: archive.id)
                // An old restore must never clear a newer preview's identity.
                if openedArchiveID == archive.id {
                    openedArchiveID = nil
                    openedArchiveGeneration = nil
                }
                _finishOperation(attempt)
            }
            do {
                let summary = try await services.backups.restore(archive, components: components)
                // Restore may already have committed. Cancellation retires this
                // presentation, not the authoritative restored files/settings.
                guard !Task.isCancelled, presentationState.completeRestore(summary, for: attempt) else { return }
                _isWorking = false
                // Unlike an unowned GCD callback, this delay is cancelled with
                // the screen/operation. Sheet dismissal may consume it first.
                try await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled, presentationState.isCurrent(attempt) else { return }
                _presentRestoreComplete()
            } catch {
                if presentationState.isCurrent(attempt), !(error is CancellationError) { Toast.error(error.localizedDescription, duration: .long) }
            }
        }
    }

    @ViewBuilder
    private var _workingOverlay: some View {
        if _isWorking {
            ZStack {
                Color(.systemBackground).opacity(0.6).ignoresSafeArea()
                VStack(spacing: 14) {
                    ProgressView()
                    Text(.localized("Working…"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
            .transition(.opacity)
        }
    }

    private func _archiveDetail(_ archive: BackupArchiveSnapshot) -> String {
        let created = String.localized(
            "Created %@ · VexSign %@",
            arguments: archive.createdAt.formatted(date: .abbreviated, time: .shortened),
            archive.appVersion
        )
        return created + "\n" + String.localized("VexSign backup schema %lld. Other signers’ backup formats are not supported. Restoring a library copy does not restore an installed app’s private data or prove installation.", arguments: archive.schemaVersion) + "\n" + archive.integrity.summary
    }

    private func _archiveCounts(_ archive: BackupArchiveSnapshot) -> [BackupComponents: Int] {
        archive.counts
    }

    private func _runExport() {
        guard !_showExportPicker else { return }
        let pending = _pendingExport
        _pendingExport = nil
        _exportPickerGeneration = nil
        guard let pending, presentationState.isCurrent(pending.generation), let attempt = _beginOperation() else { return }
        _isWorking = true
        operation = Task { @MainActor in
            defer { _finishOperation(attempt) }
            do {
                let url = try await services.backups.makeBackup(
                    password: pending.password,
                    components: pending.components
                )
                guard !Task.isCancelled, presentationState.isCurrent(attempt) else { return }
                Toast.success(.localized("Backup created"))
                DocumentPicker.export([url])
            } catch {
                if presentationState.isCurrent(attempt), !(error is CancellationError) { Toast.error(error.localizedDescription) }
            }
        }
    }

    private func _cancelImport(for generation: UUID) {
        guard _pendingImport?.generation == generation, presentationState.isCurrent(generation) else { return }
        _password = ""; _pendingImport = nil
    }

    private func _openBackup(for generation: UUID) {
        guard let pending = _pendingImport, pending.generation == generation,
              presentationState.isCurrent(generation) else { return }
        let password = _password
        _password = ""; _pendingImport = nil
        guard let attempt = _beginOperation() else { return }
        _isWorking = true
        operation = Task { @MainActor in
            defer { _finishOperation(attempt) }
            do {
                let archive = try await services.backups.open(pending.url, password: password)
                guard !Task.isCancelled, presentationState.isCurrent(attempt) else {
                    services.backups.release(archiveID: archive.id)
                    return
                }
                guard !archive.contents.isEmpty else {
                    services.backups.release(archiveID: archive.id)
                    Toast.error(.localized("This backup is empty."))
                    return
                }
                _releaseArchive()
                openedArchiveID = archive.id
                openedArchiveGeneration = attempt
                _archive = archive
            } catch {
                if presentationState.isCurrent(attempt), !(error is CancellationError) { Toast.error(error.localizedDescription) }
            }
        }
    }

    private func _presentRestoreComplete() {
        // Only a dismissed, idle preview may be released by the sheet callback.
        // A late dismissal cannot release a newly displayed archive.
        guard !_isWorking, _archive == nil else { return }
        _releaseArchive()
        guard let presenter = UIApplication.topViewController(),
              let completion = presentationState.takeRestoreCompletion() else { return }
        let summary = completion.summary
        let needsRestart = !summary.restored.intersection([.settings, .certificates]).isEmpty
        let message = needsRestart
            ? summary.lines.joined(separator: "\n") + "\n\n" + .localized("VexSign will restart to apply the backup.")
            : summary.lines.joined(separator: "\n")

        UIAlertController.showAlert(
            presenter,
            title: .localized("Restore Complete"),
            message: message,
            actions: [
                needsRestart
                ? UIAlertAction(title: .localized("Restart"), style: .default) { _ in
                    guard presentationState.isCurrent(completion.generation) else { return }
                    UIApplication.shared.suspendAndReopen()
                }
                : UIAlertAction(title: .localized("Done"), style: .default, handler: nil)
            ]
        )
    }
}
