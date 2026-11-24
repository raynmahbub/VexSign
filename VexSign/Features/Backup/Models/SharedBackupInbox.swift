import Foundation
import Combine

/// One staged backup waiting for the user, handed over by Files, AirDrop, a
/// share sheet or “Open in”.
///
/// Holding a URL here carries no authority: the file is already a private copy
/// in the app's temporary directory, and this value only says the app should
/// *offer* a restore. Decryption, password entry, component selection and the
/// restore itself stay in `BackupView`, so a handed-over file cannot restore
/// anything by itself.
@MainActor
final class SharedBackupInbox: ObservableObject {
    struct Staged: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        let receivedAt: Date
    }

    /// The most recent staged file. Assigning replaces any earlier offer rather
    /// than queueing several restores the user never asked for.
    ///
    /// Settable because a dismissed sheet clears the binding; `clear(id:)` remains the
    /// path for code that must not drop a newer offer than the one it answered.
    @Published var staged: Staged?

    func stage(_ url: URL, now: Date = Date()) {
        staged = Staged(url: url, receivedAt: now)
    }

    /// Clears the offer. The staged copy itself is removed with the temporary
    /// directory; this only stops the sheet from presenting again.
    func clear(_ id: UUID) {
        guard staged?.id == id else { return }
        staged = nil
    }
}
