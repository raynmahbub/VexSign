import Foundation
import NimbleExtensions

extension AppleAccountProvisioningProgress.Stage {
    var title: String {
        switch self {
        case .preflight: .localized("Checking Apple inventory…")
        case .identity: .localized("Preparing signing identity…")
        case .certificateApproval: .localized("Requesting certificate creation approval…")
        case .registration: .localized("Registering device & App ID…")
        case .appRegistration: .localized("Registering App ID…")
        case .profile: .localized("Creating provisioning profile…")
        case .completed: .localized("Provisioning complete!")
        }
    }
}
extension AppleAccountWorkspaceError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .approvalRequired: .localized("Review and approve this account operation before continuing.")
        case .incompatibleRenewalSource: .localized("The library copy needs a verified embedded development profile for this team, app and device. Nothing was renewed.")
        case .expiryNotAdvanced: .localized("Apple did not return a later-expiring profile. No signing identity was imported and no install was queued.")
        case .missingReceipt: .localized("The profile result is no longer available. Review the current account and try again.")
        case .noActiveContext: .localized("No active signing context")
        }
    }
}
