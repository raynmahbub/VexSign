import Foundation
import NimbleExtensions

// What the Apple account session layer says when it refuses.
//
// The two enums live in files that `Packages/NativeSigning/Services/` mirrors
// byte-identically (a link-smoke test asserts the bytes), so their declarations stay as they
// are and the user-facing copy lives here, next to them rather than inside them.
//
// Before this file, both were a bare `Error`. `localizedDescription` then produced
// "The operation couldn't be completed. (VexSign.AppleAccountSessionCoordinatorError error 2.)"
// — a message that names a type and an ordinal. A sign-in that stops on `resumeRequired` or a
// journal that fails on `invalidJournal` gave the user nothing to act on.
//
// Each sentence states what happened to the saved session and which exit applies. None of them
// interpolates a reference, a path or a token: those are Keychain keys, not information, and an
// error string is copied into logs and support reports.

extension AppleAccountSessionCoordinatorError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .cleanupRequired:
            return .localized("A previous sign-out did not finish, so no session material may be written yet. Retry signing out.")
        case .invalidSessionMetadata:
            return .localized("Apple returned a session without a usable team, or one that has already expired. Sign in again.")
        case .resumeRequired:
            return .localized("A saved Apple account session is waiting to be checked. Continue with it, or sign out first.")
        case .authenticationInProgress:
            return .localized("An Apple account sign-in is already in progress. Finish or cancel it before starting another.")
        }
    }
}

extension AppleAccountSessionRepositoryError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unsupportedJournalVersion:
            return .localized("This Apple account session was saved by a newer version of VexSign. Update the app, or sign out to clear it.")
        case .invalidJournal:
            return .localized("The saved Apple account session record is damaged, so it cannot be trusted. Sign out to clear it, then sign in again.")
        case .sessionAlreadySelected:
            return .localized("Another Apple account session is already in use. Sign out before selecting a different one.")
        case .staleReference:
            return .localized("The saved Apple account session changed while it was being checked. Sign out and sign in again.")
        case .missingSelectedSession:
            return .localized("The selected Apple account session is no longer stored on this device. Sign out and sign in again.")
        case .signOutIncomplete:
            return .localized("Signing out of the Apple account did not finish. Retry, so no session material is left behind.")
        }
    }
}
