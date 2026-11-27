//
//  VaultModels.swift
//  VexSign
//
//  Public, non-secret descriptions of the certificate vault. Nothing here can
//  hold a password, a private key, or a PKCS#12 payload: those never leave the
//  Keychain, and Keychain handles are resolved only inside the vault actor.
//

import Foundation
import Security

/// State of the Keychain-held private key for a vault certificate.
enum VaultKeyState: String, Codable, Sendable {
    case accessible
    case missing
    case inaccessible
}

/// Whether a profile's metadata was read, and whether it is currently usable.
/// Parsing and validity are deliberately separate: an expired Apple-signed
/// profile is still parsed successfully and must still be inspectable.
enum VaultProfileParseStatus: String, Codable, Sendable {
    case parsed
    case incomplete
    case invalid
    case unsupported
}

enum VaultProfileValidity: String, Codable, Sendable {
    case valid
    case expired
    case notYetValid
    case unknown
}

/// The explicit result of asking whether a certificate and a profile can be
/// used together. `requiresAdditionalValidation` is not a synonym for success.
enum VaultAssociationOutcome: String, Codable, Sendable {
    case compatible
    case incompatible
    case expired
    case invalid
    case unsupported
    case incomplete
    case requiresAdditionalValidation
}

/// One bounded, renderable entitlement value. Entitlements are metadata, not
/// secrets, but arbitrary plist objects are reduced to display strings here so
/// the vault's persisted inventory stays a simple, auditable JSON document.
struct VaultEntitlement: Codable, Equatable, Sendable {
    let key: String
    let value: String
}

/// Metadata only. `id` is derived from the certificate's SHA-256 fingerprint,
/// so renaming, re-importing, or a different display name cannot change it.
struct VaultCertificate: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let fingerprint: String
    let displayName: String
    let commonName: String?
    let issuerCommonName: String?
    let teamIdentifier: String?
    let serialNumber: String?
    let notBefore: Date?
    let notAfter: Date?
    let keyAlgorithm: String?
    let keySizeBits: Int?
    let importedAt: Date
    let keyState: VaultKeyState

    func isExpired(at date: Date = Date()) -> Bool {
        guard let notAfter else { return false }
        return notAfter <= date
    }

    var shortFingerprint: String { String(fingerprint.prefix(12)).uppercased() }
}

/// A parsed provisioning profile. Device identifiers are metadata from a
/// user-imported file; they are shown in the detail view but never logged.
struct VaultProfile: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var uuid: String
    var name: String
    var appIdentifier: String?
    var teamIdentifier: String?
    var teamName: String?
    var applicationIdentifierPrefixes: [String]
    var platforms: [String]
    var creationDate: Date?
    var expirationDate: Date?
    var type: String
    var distribution: String
    var provisionsAllDevices: Bool
    var provisionedDevices: [String]
    var entitlements: [VaultEntitlement]
    var capabilities: [String]
    var certificateFingerprints: [String]
    var parseStatus: VaultProfileParseStatus
    var validity: VaultProfileValidity
    var limitations: [String]
    var importedAt: Date

    func isExpired(at date: Date = Date()) -> Bool {
        guard let expirationDate else { return false }
        return expirationDate <= date
    }
}

/// The app description used by compatibility checks. `entitlements == nil`
/// means "the caller could not read the app's entitlements", which is different
/// from an empty, known set of entitlements.
struct VaultCompatibilityTarget: Codable, Equatable, Sendable {
    let bundleIdentifier: String?
    let teamIdentifier: String?
    let entitlements: [String: String]?
    let platforms: [String]
    let nestedBundleIdentifiers: [String]
    let deviceIdentifier: String?
    let requiresJIT: Bool

    init(
        bundleIdentifier: String?,
        teamIdentifier: String? = nil,
        entitlements: [String: String]? = nil,
        platforms: [String] = [],
        nestedBundleIdentifiers: [String] = [],
        deviceIdentifier: String? = nil,
        requiresJIT: Bool = false
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.teamIdentifier = teamIdentifier
        self.entitlements = entitlements
        self.platforms = platforms
        self.nestedBundleIdentifiers = nestedBundleIdentifiers
        self.deviceIdentifier = deviceIdentifier
        self.requiresJIT = requiresJIT
    }
}

/// An evaluated certificate/profile pair. Persisted with the target so a
/// later change to the inventory can be re-evaluated without guessing it.
struct VaultAssociation: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let certificateID: String
    let profileID: String
    let outcome: VaultAssociationOutcome
    let reasons: [String]
    let target: VaultCompatibilityTarget
    let evaluatedAt: Date

    init(
        certificateID: String,
        profileID: String,
        outcome: VaultAssociationOutcome,
        reasons: [String],
        target: VaultCompatibilityTarget,
        evaluatedAt: Date = Date()
    ) {
        self.id = certificateID + "|" + profileID
        self.certificateID = certificateID
        self.profileID = profileID
        self.outcome = outcome
        self.reasons = reasons
        self.target = target
        self.evaluatedAt = evaluatedAt
    }
}

struct VaultReadiness: Equatable, Sendable {
    enum State: String, Sendable {
        case ready
        case requiresValidation
        case blocked
        case unavailable
    }

    let state: State
    let certificateID: String?
    let profileID: String?
    let explanation: [String]
}

/// The result of opening a PKCS#12 in memory. `identity` is a Keychain-ready
/// reference and never a stored file; tests use a nil identity with a fake
/// Keychain so the import policy can be exercised without real credentials.
struct VaultOpenedIdentity {
    let identity: SecIdentity?
    let metadata: VaultIdentityMetadata
}

struct VaultIdentityMetadata: Equatable, Sendable {
    let fingerprint: String
    let commonName: String?
    let issuerCommonName: String?
    let teamIdentifier: String?
    let serialNumber: String?
    let notBefore: Date?
    let notAfter: Date?
    let keyAlgorithm: String?
    let keySizeBits: Int?
}

/// The complete vault inventory. Only public metadata is written to disk.
struct VaultStoredState: Codable, Equatable, Sendable {
    var schema: Int = 1
    var certificates: [VaultCertificate] = []
    var profiles: [VaultProfile] = []
    var associations: [VaultAssociation] = []

    static var empty: Self { Self() }
}

enum VaultError: LocalizedError, Equatable {
    case cancelled
    case restrictedFile
    case tooLarge
    case wrongPassword
    case malformedIdentity
    case missingPrivateKey
    case multipleIdentities
    case unsupportedKey
    case keychainUnavailable
    case keychainWriteFailed
    case duplicateCertificate
    case certificateNotFound
    case profileNotFound
    case replacementRequiresSameIdentity
    case invalidProfile
    case unsupportedProfile
    case incompleteProfile
    case saveFailed
    case invalidTarget

    var errorDescription: String? {
        switch self {
        case .cancelled: return "Import was cancelled. No certificate or profile was changed."
        case .restrictedFile: return "The selected file could not be accessed. Pick it again from the Files app."
        case .tooLarge: return "The selected file exceeds the vault's import size limit."
        case .wrongPassword: return "The PKCS#12 password was not accepted. The certificate was not imported."
        case .malformedIdentity: return "The PKCS#12 file is malformed or unsupported. No private key was stored."
        case .missingPrivateKey: return "A certificate without its matching private key is not a signing identity."
        case .multipleIdentities: return "This file contains more than one identity. Import one identity at a time."
        case .unsupportedKey: return "This private-key algorithm is not supported by the native identity proof."
        case .keychainUnavailable: return "The Keychain is unavailable. Unlock the device and try again."
        case .keychainWriteFailed: return "The identity could not be stored in the Keychain. No vault entry was committed."
        case .duplicateCertificate: return "This certificate is already in the vault. Use Replace to change its stored identity."
        case .certificateNotFound: return "The certificate is no longer in the vault."
        case .profileNotFound: return "The provisioning profile is no longer in the vault."
        case .replacementRequiresSameIdentity: return "Replace can only update the same certificate; import the new identity separately."
        case .invalidProfile: return "The provisioning profile is not an authenticated, readable Apple profile."
        case .unsupportedProfile: return "This provisioning profile format is not supported."
        case .incompleteProfile: return "The provisioning profile is missing metadata needed for compatibility checks."
        case .saveFailed: return "The vault inventory could not be saved. No change was reported as complete."
        case .invalidTarget: return "The app target does not have enough information for a compatibility check."
        }
    }
}

/// Stable, name-independent identifiers.
enum VaultIdentifier {
    static func certificateID(fingerprint: String) -> String { "cert-" + fingerprint.lowercased() }
    static func profileID(uuid: String) -> String { "profile-" + uuid.lowercased() }
    static func keychainLabel(certificateID: String) -> String { "com.vexsign.vault.identity." + certificateID }
}
