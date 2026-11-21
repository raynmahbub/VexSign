import SwiftUI
import NimbleExtensions

/// The restore flow for a backup that arrived from outside the app.
///
/// The file has already been staged by `DeepLinkRouterUseCase`; nothing here is
/// automatic. The sheet first says which file arrived, then hands off to the
/// existing `BackupView`, which owns the password prompt, preview, component
/// selection and restore. Dismissing never restores anything.
@MainActor
struct SharedBackupRestoreSheet: View {
    let staged: SharedBackupInbox.Staged
    let onDiscard: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showsRestore = false

    var body: some View {
        if showsRestore {
            // One presentation, two states: switching content inside the sheet
            // avoids dismissing one sheet to present another, which can leave the
            // system's blurred backdrop behind on iOS.
            NavigationStack {
                BackupView(initialBackup: staged.url)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(.localized("Close")) { close() }
                        }
                    }
            }
        } else {
            NavigationStack {
                NBList(.localized("Restore Backup")) {
                    Section {
                        LabeledContent(.localized("File"), value: staged.url.lastPathComponent)
                        LabeledContent(
                            .localized("Received"),
                            value: staged.receivedAt.formatted(date: .abbreviated, time: .shortened)
                        )
                    } footer: {
                        Text(.localized("This file was handed to VexSign from outside the app. Opening it here does not restore anything yet: you will be asked for its password, then choose exactly what comes back. Backups made without a password are encrypted for the device that created them."))
                    }

                    Section {
                        Button {
                            showsRestore = true
                        } label: {
                            Label(.localized("Open in Backups"), systemImage: "arrow.right.circle.fill")
                        }

                        Button(role: .destructive) {
                            close()
                        } label: {
                            Label(.localized("Discard"), systemImage: "trash")
                        }
                    } footer: {
                        Text(.localized("Discarding only forgets this offer. The staged copy is removed from the app's temporary files."))
                    }
                }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(.localized("Close")) { close() }
                    }
                }
            }
        }
    }

    private func close() {
        onDiscard()
        dismiss()
    }
}
