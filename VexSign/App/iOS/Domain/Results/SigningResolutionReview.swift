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
struct SigningResolutionAuthorization: Equatable, Sendable {
    let fingerprint: String
    let plannedRemovals: [String]
    var sourceFingerprint: String? = nil
}

struct SigningResolutionReview: Sendable {
    var components: [SigningComponentReview] = []
    var inventoryNotices: [String] = []
    var plannedRemovals: [String] = []
    var authorization: SigningResolutionAuthorization?
    var isReady: Bool { !components.isEmpty && components.allSatisfy { $0.status == .valid } }
    var mainIdentityReference: String? { components.first?.identityReference }
}
