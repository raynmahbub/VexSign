// MARK: - UnifiedSigningIdentity
//
// A read-only projection over VexSign's existing owners. It does NOT create a
// second certificate vault and it does NOT sign anything. The Core Data
// certificate store remains the only engine-ready source (p12 + Keychain
// password); the separate Keychain-only vault is represented honestly as
// non-engine-ready because iOS cannot export a SecIdentity as PKCS#12.
//
// Every field is metadata observed from an actual certificate/profile or
// explicitly unknown. No name, filename or provider badge is used to infer
// paid/free status or certificate type.

import Foundation
import NimbleExtensions

enum UnifiedIdentitySource: String, Codable, Equatable, Sendable, CaseIterable {
    case appleAccount
    case appleFreeAccount
    case applePaidDeveloper
    case externalImport
    case externalProvider
    case unknown

    var displayName: String {
        switch self {
        case .appleAccount: return .localized("Apple Account handoff")
        case .appleFreeAccount: return .localized("Apple free account")
        case .applePaidDeveloper: return .localized("Apple Developer Program")
        case .externalImport: return .localized("Imported certificate")
        case .externalProvider: return .localized("External provider")
        case .unknown: return .localized("Source unknown")
        }
    }
}

/// Derived from the associated signed profile, never from a certificate name.
/// `unknown` is the only honest answer when the profile could not be read.
enum SigningCertificateType: String, Codable, Equatable, Sendable, CaseIterable {
    case development
    case adHoc
    case enterprise
    case distribution
    case unknown

    init(_ profileType: ProvisionProfileType) {
        switch profileType {
        case .development: self = .development
        case .adHoc: self = .adHoc
        case .enterprise: self = .enterprise
        case .distribution: self = .distribution
        case .unknown: self = .unknown
        }
    }

    var displayName: String {
        switch self {
        case .development: return .localized("Development")
        case .adHoc: return .localized("Ad Hoc")
        case .enterprise: return .localized("Enterprise")
        case .distribution: return .localized("Distribution")
        case .unknown: return .localized("Unknown")
        }
    }
}

enum SigningIdentityValidityState: String, Codable, Equatable, Sendable {
    case valid
    case expiringSoon
    case expired
    case keyMissing
    case revoked
    case unknown

    var displayName: String {
        switch self {
        case .valid: return .localized("Valid")
        case .expiringSoon: return .localized("Expiring soon")
        case .expired: return .localized("Expired")
        case .keyMissing: return .localized("Private key unavailable")
        case .revoked: return .localized("Revoked")
        case .unknown: return .localized("Unknown")
        }
    }

    var isSigningAdmissible: Bool { self == .valid || self == .expiringSoon }
}

struct UnifiedSigningIdentity: Identifiable, Equatable, Sendable {
    /// Stable identity of the backing record: an engine reference for Core Data
    /// rows, or the fingerprint-derived vault identifier.
    let id: String
    let displayName: String
    let source: UnifiedIdentitySource
    let certificateType: SigningCertificateType
    let teamIdentifier: String?
    let fingerprint: String?
    let notBefore: Date?
    let notAfter: Date?
    let privateKeyAvailable: Bool
    let associatedProfileIDs: [String]
    let supportedPlatforms: [String]
    let capabilities: [String]
    let validityState: SigningIdentityValidityState
    /// Only true for an identity the existing signing engine can consume without
    /// exporting a key: a staged PKCS#12 whose password is in the Keychain.
    let engineReady: Bool
    let engineReference: String?
    var providerID: SigningProviderID?
    let notices: [String]

    var canStartNativeSigning: Bool { engineReady && validityState.isSigningAdmissible }
}

// MARK: - Catalog

enum UnifiedIdentityCatalog {
    struct EngineCandidate {
        let input: SigningIdentityStore.Input
        let record: CertificateRecord
    }

    /// Projects the existing engine-ready store. Profile facts come from the
    /// decoded profile the user imported; source is external unless a separate,
    /// verified Apple Account handoff supplied the record.
    static func engineIdentities(
        from candidates: [EngineCandidate],
        now: Date = Date(),
        provenance: (String?) -> SigningIdentityProvenance? = { SigningIdentityProvenanceStore.source(for: $0) }
    ) -> [UnifiedSigningIdentity] {
        candidates.map { candidate in
            let profile = candidate.record.profile
            let keyAvailable = candidate.input.password != nil && candidate.input.p12URL != nil
            let validity: SigningIdentityValidityState
            if candidate.record.revoked || candidate.input.revoked {
                validity = .revoked
            } else if !keyAvailable {
                validity = .keyMissing
            } else if let expiry = candidate.record.expiration, expiry <= now {
                validity = .expired
            } else if let expiry = candidate.record.expiration,
                      expiry.timeIntervalSince(now) <= 7 * 86_400 {
                validity = .expiringSoon
            } else if candidate.record.expiration == nil {
                validity = .unknown
            } else {
                validity = .valid
            }
            var notices = [String]()
            if let note = candidate.input.notice, !note.isEmpty { notices.append(note) }
            if !keyAvailable {
                notices.append(.localized("The staged PKCS#12 or its Keychain password is unavailable; this identity cannot sign."))
            }
            if profile == nil {
                notices.append(.localized("No readable provisioning profile is associated with this identity."))
            }
            // Source comes only from an explicit record written by the importer.
            // An unlabelled identity stays external/unknown; names never count.
            let recorded = provenance(candidate.record.uuid)
            let source: UnifiedIdentitySource = {
                switch recorded {
                case .appleAccountHandoff: return .appleAccount
                case .communityNexCerts: return .externalProvider
                case .importedByUser, nil: return .externalImport
                }
            }()
            if source == .appleAccount {
                notices.append(.localized("Apple Account handoff: free vs paid enrollment is not inferred from the certificate name. The account type is not verified here."))
            }
            return UnifiedSigningIdentity(
                id: candidate.input.reference,
                displayName: candidate.record.workspaceName.isEmpty ? candidate.input.name : candidate.record.workspaceName,
                source: source,
                certificateType: SigningCertificateType(profile?.profileType ?? .unknown),
                teamIdentifier: profile?.TeamIdentifier.first,
                fingerprint: nil,
                notBefore: profile?.CreationDate,
                notAfter: candidate.record.expiration ?? profile?.ExpirationDate,
                privateKeyAvailable: keyAvailable,
                associatedProfileIDs: profile.map { [$0.UUID] } ?? [],
                supportedPlatforms: profile?.Platform ?? [],
                capabilities: (profile?.entitlementKeys ?? []).sorted(),
                validityState: validity,
                engineReady: true,
                engineReference: candidate.input.reference,
                providerID: [.appleAccount, .appleFreeAccount, .applePaidDeveloper].contains(source)
                    ? .appleDeveloper : (source == .externalProvider ? .communityNexCerts : .localCertificateFiles),
                notices: notices
            )
        }
    }

    /// Projects the separate Keychain-only vault without pretending its
    /// identities can be fed to Zsign. This is a view of a vault, not a copy.
    static func vaultIdentities(
        certificates: [VaultCertificate],
        profiles: [VaultProfile],
        now: Date = Date()
    ) -> [UnifiedSigningIdentity] {
        certificates.map { certificate in
            let linked = profiles.filter { profile in
                profile.certificateFingerprints.contains(certificate.fingerprint.lowercased())
                    || profile.teamIdentifier == certificate.teamIdentifier
            }
            let validity: SigningIdentityValidityState
            if certificate.isExpired(at: now) {
                validity = .expired
            } else if certificate.keyState != .accessible {
                validity = .keyMissing
            } else if let expiry = certificate.notAfter,
                      expiry.timeIntervalSince(now) <= 7 * 86_400 {
                validity = .expiringSoon
            } else if certificate.notAfter == nil {
                validity = .unknown
            } else {
                validity = .valid
            }
            let type = SigningCertificateType(linked.first.flatMap { ProvisionProfileType(rawValue: $0.type) } ?? .unknown)
            return UnifiedSigningIdentity(
                id: certificate.id,
                displayName: certificate.displayName,
                source: .externalImport,
                certificateType: type,
                teamIdentifier: certificate.teamIdentifier,
                fingerprint: certificate.fingerprint,
                notBefore: certificate.notBefore,
                notAfter: certificate.notAfter,
                privateKeyAvailable: certificate.keyState == .accessible,
                associatedProfileIDs: linked.map(\.id),
                supportedPlatforms: linked.first?.platforms ?? [],
                capabilities: linked.first?.entitlements.map(\.key).sorted() ?? [],
                validityState: validity,
                engineReady: false,
                engineReference: nil,
                providerID: nil,
                notices: [
                    .localized("This identity lives in the Keychain vault. iOS cannot export its private key as PKCS#12; import the original certificate files into the signing store to use it for signing.")
                ]
            )
        }
    }

    static func profileClass(from profile: VaultProfile?) -> ProvisionProfileType {
        guard let profile else { return .unknown }
        switch (profile.type.lowercased(), profile.distribution.lowercased()) {
        case let (type, _) where type.contains("enterprise") || profile.provisionsAllDevices:
            return .enterprise
        case let (type, _) where type.contains("development"):
            return .development
        case let (_, distribution) where distribution.contains("adhoc") || distribution.contains("ad hoc"):
            return .adHoc
        case let (type, _) where type.contains("distribution"):
            return .distribution
        default:
            return .unknown
        }
    }
}

/// A single input shape for the signing engine. The engine still receives the
/// same `SigningEngineRequest`; this resolves an identity to its existing
/// Core Data reference without introducing a second signer.
struct EngineIdentityBinding: Equatable, Sendable {
    let identity: UnifiedSigningIdentity

    func validate() throws {
        guard identity.engineReady, let reference = identity.engineReference,
              identity.canStartNativeSigning else {
            throw SigningIdentityBindingError.notEngineReady
        }
        guard reference.utf8.count <= 2048,
              !reference.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" }) else {
            throw SigningIdentityBindingError.invalidReference
        }
    }
}

enum SigningIdentityBindingError: Error, LocalizedError, Equatable {
    case notEngineReady
    case invalidReference
    case incompatibleProfile

    var errorDescription: String? {
        switch self {
        case .notEngineReady:
            return .localized("This identity is not usable by the native signing engine. Import the original PKCS#12 and provisioning profile into the signing store first.")
        case .invalidReference:
            return .localized("The selected signing identity reference is invalid. Review the identity again.")
        case .incompatibleProfile:
            return .localized("The selected provisioning profile is not compatible with this identity and app. Nothing was signed.")
        }
    }
}
