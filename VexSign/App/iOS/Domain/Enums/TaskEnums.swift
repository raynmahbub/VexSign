import Foundation

enum UnifiedTaskKind: String, Codable, CaseIterable, Sendable {
	case download
	case importIPA = "import"
	case sign
	case install
	case update
	case export

}

enum UnifiedTaskPhase: String, Codable, CaseIterable, Sendable {
	case queued
	case downloading
	case extracting
    case importing, readyToSign, signed, preparingInstallation, waitingForIOS, verifying
	case signing
	case installing
	case completed
	case failed
	case cancelled
    case interrupted
	/// VexSign finished, but iOS never exposed enough evidence to say whether the
	/// app was installed. Not a success claim and not a failure: private
	/// LaunchServices lookups are filtered on modern iOS, so an install that
	/// worked can be unobservable. Reporting that as "Failed" told users to retry
	/// an app that was already on their Home Screen.
	case unconfirmed

	/// Paused is a sub-state of downloading surfaced by the task center.
	case paused

    /// Separate operations share one vocabulary, not one success verdict.
    /// Queue installs can start a new item at preparation after verification.
    func canTransition(to next: Self, kind: UnifiedTaskKind) -> Bool {
        guard !isTerminal else { return false }
        if kind == .sign {
            if next == .failed || next == .cancelled || next == self { return true }
            switch self {
            case .queued, .readyToSign: return next == .signing
            case .signing: return next == .signed || next == .completed
            case .signed: return next == .completed
            default: return false
            }
        }
        if kind == .install {
            if next == self || next == .failed || next == .cancelled || next == .unconfirmed { return true }
            switch self {
            case .queued: return next == .preparingInstallation
            case .preparingInstallation: return next == .waitingForIOS || next == .installing
            case .waitingForIOS: return next == .installing || next == .verifying
            case .installing: return next == .verifying || next == .completed
            case .verifying: return next == .completed
            default: return false
            }
        }
        return true
    }

	var isTerminal: Bool {
		self == .completed || self == .failed || self == .cancelled || self == .interrupted
			|| self == .unconfirmed
	}

	var isInProgress: Bool { !isTerminal }
}

enum TaskRecoveryGuide: Equatable {
    case download, archive, signing, installation, general

    static func resolve(kind: UnifiedTaskKind, failureStage: UnifiedTaskPhase?) -> Self {
        switch failureStage {
        case .downloading: return .download
        case .extracting, .importing, .readyToSign: return .archive
        case .signing: return .signing
        case .installing, .preparingInstallation, .waitingForIOS, .verifying: return .installation
        default:
            switch kind {
            case .download: return .download
            case .importIPA: return .archive
            case .sign: return .signing
            case .install: return .installation
            case .update, .export: return .general
            }
        }
    }

}
