// MARK: - Unified application-source catalog models
//
// Value types only. They are persisted through `EcosystemDatabase` and are the
// single representation used by the catalog parsers, cache, search, download
// resolution and update detection. Nothing here performs I/O or networking.

import Foundation
import NimbleExtensions

enum CatalogSourceFormat: String, Codable, CaseIterable, Sendable, Identifiable {
    case altStore
    case sideStore
    case feather
    case esign
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .altStore: .localized("AltStore")
        case .sideStore: .localized("SideStore")
        case .feather: .localized("Feather")
        case .esign: .localized("ESign")
        case .custom: .localized("Custom")
        }
    }

    /// The repository dialect this build can actually parse for a registered format.
    var supportedSchemaVersions: Set<Int> {
        switch self {
        case .altStore, .sideStore, .feather, .esign: [1, 2]
        case .custom: [1]
        }
    }

    init(format: RepositoryFormat) {
        switch format {
        case .altStore: self = .altStore
        case .sideStore: self = .sideStore
        case .feather: self = .feather
        case .esign: self = .esign
        case .custom: self = .custom
        }
    }
}

enum CatalogValidationState: String, Codable, Sendable {
    case unverified
    case valid
    case invalid
    case unsupportedSchema
    case stale
}

enum CatalogSourceAvailability: String, Codable, Sendable {
    case healthy
    case stale
    case unavailable
    case invalid
    case rateLimited
    case disabled
    case unknown
}

struct CatalogSourceHealth: Codable, Equatable, Sendable {
    var lastSuccessfulRefresh: Date?
    var lastFailedRefresh: Date?
    var lastError: String?
    var httpFailures: Int = 0
    var parseFailures: Int = 0
    var schemaFailures: Int = 0
    var consecutiveFailures: Int = 0
    var lastRefreshDuration: TimeInterval = 0
    var lastStatusCode: Int?

    var availability: CatalogSourceAvailability {
        if lastError?.lowercased().contains("rate limit") == true { return .rateLimited }
        if let failure = lastError, !failure.isEmpty { return .unavailable }
        guard lastSuccessfulRefresh != nil else { return .unknown }
        if Date().timeIntervalSince(lastSuccessfulRefresh!) > CatalogFreshness.staleInterval { return .stale }
        return .healthy
    }
}

enum CatalogFreshness {
    static let staleInterval: TimeInterval = 24 * 60 * 60
}

struct CatalogSourceRecord: Codable, Equatable, Sendable, Identifiable {
    /// Stable identifier derived from the configured repository address.
    let id: String
    var declaredIdentifier: String?
    var name: String
    var url: String
    var format: CatalogSourceFormat
    var schemaVersion: Int?
    var summary: String?
    var artworkURL: String?
    var enabled: Bool = true
    var validationState: CatalogValidationState = .unverified
    var health: CatalogSourceHealth = CatalogSourceHealth()
    var applicationCount: Int = 0
    var createdAt: Date
    var updatedAt: Date

    /// Whether a catalog signed by a third party was cryptographically verified.
    /// An unsigned feed is always `false`; a reachable URL is never trust evidence.
    var integrityVerified: Bool = false

    init(
        id: String,
        declaredIdentifier: String? = nil,
        name: String,
        url: String,
        format: CatalogSourceFormat = .altStore,
        schemaVersion: Int? = nil,
        summary: String? = nil,
        artworkURL: String? = nil,
        enabled: Bool = true,
        validationState: CatalogValidationState = .unverified,
        health: CatalogSourceHealth = CatalogSourceHealth(),
        applicationCount: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        integrityVerified: Bool = false
    ) {
        self.id = id
        self.declaredIdentifier = declaredIdentifier
        self.name = name
        self.url = url
        self.format = format
        self.schemaVersion = schemaVersion
        self.summary = summary
        self.artworkURL = artworkURL
        self.enabled = enabled
        self.validationState = validationState
        self.health = health
        self.applicationCount = applicationCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.integrityVerified = integrityVerified
    }
}

struct CatalogDiagnostic: Codable, Equatable, Sendable, Identifiable {
    enum Severity: String, Codable, Sendable { case error, warning, informational }

    let id: String
    let severity: Severity
    let code: String
    let message: String
    let property: String?

    init(id: String = UUID().uuidString, severity: Severity, code: String, message: String, property: String? = nil) {
        self.id = id
        self.severity = severity
        self.code = code
        self.message = message
        self.property = property
    }
}

struct CatalogRelease: Codable, Equatable, Sendable, Identifiable {
    let version: String
    let date: String?
    let downloadURL: String
    let size: Int64?
    let sha256: String?
    let changelog: String?
    let minimumOSVersion: String?
    let supportedDevices: [String]
    let installName: String?

    var id: String { version + "|" + downloadURL }
}

struct CatalogAppRecord: Codable, Equatable, Sendable, Identifiable {
    /// Source-scoped identity: the same bundle identifier from two repositories
    /// remains two listings until a deliberate cross-source choice is made.
    let id: String
    let sourceID: String
    let sourceName: String
    let sourceURL: String
    let bundleIdentifier: String
    let name: String
    let developer: String?
    let summary: String?
    let description: String?
    let iconURL: String?
    let screenshotURLs: [String]
    let category: String?
    let tintColor: String?
    let releases: [CatalogRelease]
    let permissions: [String]
    /// Unknown provider fields survive parsing; they are never interpreted as
    /// local paths, scripts or download instructions.
    let extra: [String: RepositoryJSON]
    let fetchedAt: Date
    var metadataIsVerified: Bool

    var latest: CatalogRelease? { releases.first }

    var currentVersion: String? { latest?.version }

    var currentDownloadURL: String? { latest?.downloadURL }

    var currentIntegrity: CatalogDownloadExpectation {
        CatalogDownloadExpectation(byteCount: latest?.size, sha256: latest?.sha256)
    }
}

struct CatalogDownloadExpectation: Codable, Equatable, Sendable {
    var byteCount: Int64?
    var sha256: String?

    var isEmpty: Bool { byteCount == nil && sha256 == nil }
}

struct CatalogSnapshot: Codable, Equatable, Sendable {
    let sourceID: String
    let format: CatalogSourceFormat
    let schemaVersion: Int
    let fetchedAt: Date
    let sha256: String
    let name: String?
    let summary: String?
    let artworkURL: String?
    let apps: [CatalogAppRecord]
    /// Non-fatal findings from the parser. Fatal findings refuse the whole snapshot.
    let diagnostics: [CatalogDiagnostic]
}

/// A cross-source view used for search: one canonical app can expose several
/// source listings, but only one is selected at a time.
struct CatalogSearchHit: Identifiable, Equatable, Sendable {
    struct Listing: Identifiable, Equatable, Sendable {
        var id: String { app.id }
        let app: CatalogAppRecord
    }

    let bundleKey: String
    let name: String
    let developer: String?
    var listings: [Listing]

    var id: String { bundleKey }

    var selected: CatalogAppRecord? { listings.first?.app }
}

enum CatalogUpdateVerdict: String, Codable, Sendable {
    case updateAvailable
    case upToDate
    case olderVersion
    case incompatible
    case noDownload
    case unknownVersion
    case installedAppMissing
}

struct CatalogUpdateCandidate: Identifiable, Equatable, Sendable {
    let bundleIdentifier: String
    let installedName: String
    let installedVersion: String?
    let app: CatalogAppRecord
    let release: CatalogRelease
    let verdict: CatalogUpdateVerdict
    let reason: String?

    var id: String { bundleIdentifier.lowercased() + "|" + app.sourceID + "|" + release.version }
}
