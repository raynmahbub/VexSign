// Structured, read-only description of an imported application bundle.
//
// This model is produced without executing the imported app, modifying its
// bundle, or claiming cryptographic signature validity. It is stored beside the
// library entry so signing, installation and customization can share one
// inspection result instead of reparsing the IPA.

import Foundation

struct AppBundleInspection: Codable, Equatable, Sendable {
    enum Status: String, Codable, Equatable, Sendable {
        case valid
        case incomplete
        case unsupported
        case ambiguous
        case invalid
        case inspectionFailed
    }

    enum Severity: String, Codable, Hashable, Sendable {
        case info
        case warning
        case error
    }

    struct Diagnostic: Codable, Equatable, Hashable, Sendable {
        let severity: Severity
        let code: String
        let subject: String?
        let detail: String
    }

    struct ArchiveSummary: Codable, Equatable, Sendable {
        let entryCount: Int
        let totalExpandedBytes: UInt64
        let largestEntryPath: String?
        let largestEntryBytes: UInt64
        let compressionMethods: [String]
        let hasPayloadDirectory: Bool
        let payloadAppBundleCount: Int
    }

    struct Identity: Codable, Equatable, Sendable {
        let bundleIdentifier: String?
        let name: String?
        let displayName: String?
        let executableName: String?
        let packageType: String?
    }

    struct Version: Codable, Equatable, Sendable {
        let shortVersion: String?
        let build: String?
    }

    struct Platform: Codable, Equatable, Sendable {
        let minimumOSVersion: String?
        let platformName: String?
        let platformVersion: String?
        let deviceFamilies: [Int]
    }

    struct Presentation: Codable, Equatable, Sendable {
        let displayName: String?
        let iconFiles: [String]
        let iconFile: String?
        let supportedOrientations: [String]
    }

    struct Integration: Codable, Equatable, Sendable {
        let urlSchemes: [String]
        let documentTypes: [String]
        let capabilities: [String]
    }

    enum NestedKind: String, Codable, Equatable, Sendable {
        case appExtension
        case watchApplication
        case framework
        case dynamicLibrary
        case plugIn
        case bundle
        case unsupported
    }

    struct NestedBundle: Codable, Equatable, Sendable {
        let relativePath: String
        let kind: NestedKind
        let bundleIdentifier: String?
        let name: String?
        let executableName: String?
        let architectures: [String]
        let hasInfoPlist: Bool
        let hasExecutable: Bool
        let diagnostics: [Diagnostic]
    }

    struct Executable: Codable, Equatable, Sendable {
        let name: String?
        let exists: Bool
        let isMachO: Bool
        let isUniversal: Bool
        let architectures: [String]
        let minimumOSVersion: String?
        let platform: String?
        let isEncrypted: Bool
        let hasCodeSignature: Bool
        let diagnostics: [Diagnostic]
    }

    enum SignatureStatus: String, Codable, Equatable, Sendable {
        /// No structural signature evidence was found.
        case absent
        /// A signature directory and/or a Mach-O signature command exists. It has
        /// not been cryptographically verified by this inspector.
        case structuralOnly
        /// Only a verifier that consumes authenticated assets may emit this.
        case cryptographicallyVerified
        /// Structural evidence was found but is internally inconsistent.
        case invalid
        /// The format is outside this inspector's supported set.
        case unsupported
        /// The relevant file could not be read within the inspection bounds.
        case verificationUnavailable
    }

    struct ExistingSignature: Codable, Equatable, Sendable {
        let status: SignatureStatus
        let hasSignatureDirectory: Bool
        let hasCodeResources: Bool
        let executableDeclaresSignature: Bool
        let profilePresent: Bool
        let profileReadable: Bool
        let profileExpired: Bool
        let profileUUID: String?
        let profileTeamIdentifier: String?
        let profileApplicationIdentifier: String?
        let profileExpiresAt: Date?
        let diagnostics: [Diagnostic]
    }

    let schema: Int
    let inspectedAt: Date
    let bundleName: String
    let status: Status
    let archive: ArchiveSummary?
    let identity: Identity
    let version: Version
    let platform: Platform
    let presentation: Presentation
    let integration: Integration
    let nestedBundles: [NestedBundle]
    let executable: Executable
    let signature: ExistingSignature
    let diagnostics: [Diagnostic]

    var isImportable: Bool { status != .invalid }

    var errorDiagnostics: [Diagnostic] { diagnostics.filter { $0.severity == .error } }
}

struct AppBundleInspectionResult: Sendable {
    let report: AppBundleInspection
    /// Original bytes, kept outside the app bundle so signature bytes are not modified.
    let originalInfoPlist: Data?
}
