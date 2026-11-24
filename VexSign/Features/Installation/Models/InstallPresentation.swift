import Foundation
import NimbleExtensions

extension InstallPresentation {
    func label(verificationAttempt: Int = 0) -> String {
        switch self {
        case .preparing: return .localized("Preparing")
        case .awaitingConfirmation: return .localized("Waiting for iOS confirmation")
        case .sendingManifest: return .localized("Sending installation manifest")
        case .installing: return .localized("Installing")
        case .verifying: return InstallVerificationPolicy.statusLabel(attempt: verificationAttempt)
        case .installed: return .localized("Installed")
        case .unconfirmed: return .localized("Installation not confirmed")
        case .failed: return .localized("Installation error")
        case .operationCompleted: return .localized("Completed")
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .verifying: return .localized("Verifying installation")
        case .installed: return .localized("Installation completed")
        case .failed: return .localized("Installation failed")
        default: return label()
        }
    }

    var symbol: String {
        switch self {
        case .preparing: return "archivebox.fill"
        case .awaitingConfirmation: return "clock"
        case .sendingManifest: return "paperplane.fill"
        case .installing: return "square.and.arrow.down"
        case .verifying: return "magnifyingglass"
        case .installed, .operationCompleted: return "checkmark.circle.fill"
        case .unconfirmed: return "questionmark.circle"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    var isTerminal: Bool {
        switch self {
        case .installed, .unconfirmed, .failed, .operationCompleted: return true
        default: return false
        }
    }
}
