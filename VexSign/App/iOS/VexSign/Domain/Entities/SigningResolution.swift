import Foundation

/// Value-only input to profile resolution. Paths are relative to the inspected app;
/// neither a private key nor its password belongs in this model or in diagnostics.
struct BundleSigningTarget: Identifiable {
    let relativePath: String
    let bundleIdentifier: String
    let platform: String
    let requiredEntitlements: [String: Any]
    var isolateKeychainGroups: Bool = false
    var parentBundleIdentifier: String? = nil
    var id: String { relativePath }
}

/// Safe persisted preference: public certificate/profile identifiers, not paths,
/// passwords or imported private-key bytes. A stale preference never bypasses validation.
struct ComponentSigningPreference: Codable, Equatable, Hashable, Sendable {
    let certificateFingerprint: String
    let profileUUID: String
    var id: String { certificateFingerprint + ":" + profileUUID.lowercased() }
}

enum SigningValidationStatus: String, Sendable {
    case valid, invalid, unsupported, ambiguous
}

struct SigningResolutionIssue: Equatable {
    enum Code: String {
        case authenticity, expiration, identifier, prefix, team, certificate, privateKey
        case mode, device, entitlement, platform, noCandidate, structure
    }
    let code: Code
    let detail: String
}

struct SigningIdentityCandidate {
    enum KeyAvailability { case accessible, missing, inaccessible }
    let reference: String
    let fingerprint: String
    let teamIdentifier: String?
    var displayName: String? = nil
    let notBefore: Date?
    let notAfter: Date?
    let keyAvailability: KeyAvailability
    var nativeSigningSupported: Bool = true
}

struct SigningProfileCandidate {
    /// Stable identity + profile UUID, not a display name or an array index.
    let id: String
    let identity: SigningIdentityCandidate
    let profile: Certificate
    /// Set only after CMS signature and Apple signer-chain authentication.
    let isAuthenticated: Bool
    let authorizedCertificateFingerprints: Set<String>
    var preference: ComponentSigningPreference {
        .init(certificateFingerprint: identity.fingerprint, profileUUID: profile.UUID)
    }
}

struct SigningComponentResolution: Identifiable {
    let target: BundleSigningTarget
    let status: SigningValidationStatus
    let candidate: SigningProfileCandidate?
    let issues: [SigningResolutionIssue]
    let entitlements: [String: Any]
    var id: String { target.id }
}

struct SigningResolution {
    let components: [SigningComponentResolution]
    var isReady: Bool { !components.isEmpty && components.allSatisfy { $0.status == .valid } }
    var issues: [SigningResolutionIssue] { components.flatMap(\.issues) }
}
