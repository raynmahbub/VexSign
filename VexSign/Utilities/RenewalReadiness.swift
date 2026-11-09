import Foundation

/// Evidence about retained inputs, not a claim of native signing or unattended renewal support.
struct RenewalReadinessInputs: Equatable {
    var hasLibraryBundle: Bool
    var hasSavedSettings: Bool
    var savedCertificateUUID: String?
    var resolvedCertificateUUID: String?
    var hasCertificate: Bool
    var certificateExpired: Bool
    var certificateRevoked: Bool
}

enum RenewalIdentityReadiness: Equatable {
    case missing, expired, revoked, fallback, currentSelection, savedIdentity
}

struct RenewalReadiness: Equatable {
    let hasLibraryBundle: Bool
    let hasSavedSettings: Bool
    let identity: RenewalIdentityReadiness

    init(_ inputs: RenewalReadinessInputs) {
        hasLibraryBundle = inputs.hasLibraryBundle
        hasSavedSettings = inputs.hasSavedSettings
        if !inputs.hasCertificate { identity = .missing }
        else if inputs.certificateRevoked { identity = .revoked }
        else if inputs.certificateExpired { identity = .expired }
        else if let saved = inputs.savedCertificateUUID {
            identity = saved == inputs.resolvedCertificateUUID ? .savedIdentity : .fallback
        } else { identity = .currentSelection }
    }

    var retainedInputsAvailable: Bool {
        hasLibraryBundle && hasSavedSettings && identity == .savedIdentity
    }
}
