import Foundation

/// The route that produced an install result. Unknown values intentionally stay unknown; they
/// must never fall back to OTA or paired-device semantics.
enum InstallationEvidenceMethod: Equatable, Sendable {
    case ota
    case pairedDevice
    case guestImport
    case export
    case unresolved

    init(code: String?) {
        switch code {
        case "OTA": self = .ota
        case "paired-device": self = .pairedDevice
        case "guest-import": self = .guestImport
        case "export": self = .export
        default: self = .unresolved
        }
    }

    /// Diagnostic for a producer that reports `.installed` without evidence accepted for its
    /// route. Delivery, command completion, or an unbound/private observation cannot substitute.
    var rejectedInstalledReason: String {
        switch self {
        case .ota: return "ota-completion-not-authoritative"
        case .pairedDevice: return "paired-installed-version-not-verified"
        case .guestImport: return "guest-prepared-not-installed"
        case .export: return "exported-not-installed"
        case .unresolved: return "installation-evidence-unavailable"
        }
    }
}

/// Shared success gate used at both the installer and queue boundaries. In this build the only
/// exact, identity-bound inventory evidence is from the paired-device AppService path. OTA has no
/// supported general app inventory in the sandbox, so even an injected/private probe result or a
/// successful transport callback must remain unconfirmed.
enum InstallCompletionEvidencePolicy {
    static func allowsInstalledOutcome(
        method: InstallationEvidenceMethod,
        hasExactPairedDeviceEvidence: Bool
    ) -> Bool {
        method == .pairedDevice && hasExactPairedDeviceEvidence
    }
}
