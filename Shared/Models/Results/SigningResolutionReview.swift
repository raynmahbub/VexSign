import Foundation

/// Public evidence only: no key, password, CMS payload, or device identifier.
struct SigningComponentReview: Identifiable, Sendable {
    let id: String
    let bundleIdentifier: String
    let status: SigningValidationStatus
    let certificateName: String?
    let identityReference: String?
    let profileName: String?
    let profileUUID: String?
    let profileExpiration: Date?
    let certificateExpiration: Date?
    let team: String?
    let deviceAuthorization: String
    let entitlementKeys: [String]
    let issues: [String]
    var choices: [SigningComponentChoice] = []
    var selectedChoice: String? = nil
}

struct SigningComponentChoice: Identifiable, Equatable, Sendable {
    let preference: ComponentSigningPreference
    let certificateName: String
    let profileName: String
    let expiration: Date
    var id: String { preference.id }
}

/// A consent binding, not a trust token. Every byte is authenticated again before
/// use. Changing a selected identity/profile, identifier, requested capability or
/// optional-removal list withdraws consent and requires review again.
enum SigningAuthorizationMismatch: Equatable, Sendable {
    case sourceBundle
    case optionalRemovals
    case componentPlan
    case signingIdentity
    case provisioningProfile
    case requiredCapabilities
    case targetDevice
    case authorizationMissing
    case other
}

struct SigningResolutionAuthorization: Equatable, Sendable {
    let fingerprint: String
    let plannedRemovals: [String]
    var sourceFingerprint: String? = nil
    /// Independent digests classify a failed revalidation without logging any
    /// raw certificate, profile, entitlement value, device identifier, or path.
    var componentFingerprint: String? = nil
    var identityFingerprint: String? = nil
    var profileFingerprint: String? = nil
    var requiredCapabilitiesFingerprint: String? = nil
    var deviceFingerprint: String? = nil

    func mismatch(against current: SigningResolutionAuthorization?) -> SigningAuthorizationMismatch? {
        guard let current else { return .authorizationMissing }
        if sourceFingerprint != current.sourceFingerprint { return .sourceBundle }
        if plannedRemovals != current.plannedRemovals { return .optionalRemovals }
        if componentFingerprint != current.componentFingerprint { return .componentPlan }
        if identityFingerprint != current.identityFingerprint { return .signingIdentity }
        if profileFingerprint != current.profileFingerprint { return .provisioningProfile }
        if requiredCapabilitiesFingerprint != current.requiredCapabilitiesFingerprint { return .requiredCapabilities }
        if deviceFingerprint != current.deviceFingerprint { return .targetDevice }
        return fingerprint == current.fingerprint ? nil : .other
    }
}

struct SigningResolutionReview: Sendable {
    var components: [SigningComponentReview] = []
    var inventoryNotices: [String] = []
    var plannedRemovals: [String] = []
    var authorization: SigningResolutionAuthorization?
    var isReady: Bool { !components.isEmpty && components.allSatisfy { $0.status == .valid } }
    var mainIdentityReference: String? { components.first?.identityReference }
}
