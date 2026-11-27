// MARK: - Signing provider boundary
//
// Provider-specific adapters live behind this interface. No generic "call any
// API with these fields" client exists: a provider must have a verified real
// workflow before an adapter is registered. Community NexCerts and the local
// certificate-file flow are the only external sources enabled here. Apple
// Account provisioning is owned by NativeSigning and is represented as a
// capability, not reimplemented as an HTTP provider.

import Foundation
import NimbleExtensions

enum SigningProviderID: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
    case appleDeveloper
    case localCertificateFiles
    case communityNexCerts
}

enum SigningProviderCapability: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
    case certificateList
    case certificateDownload
    case profileDownload
    case statusCheck
    case accountStatus
    case authentication
    case remoteSigning
}

struct SigningProviderDescriptor: Equatable, Sendable {
    let id: SigningProviderID
    let displayName: String
    let capabilities: Set<SigningProviderCapability>
    let limitations: [String]
    let sourceHost: String?
    let requiresExplicitDisclosure: Bool

    func supports(_ capability: SigningProviderCapability) -> Bool { capabilities.contains(capability) }
}

enum SigningProviderState: String, Codable, Equatable, Sendable {
    case notConfigured
    case available
    case rateLimited
    case unavailable
    case disconnected
}

struct SigningProviderStatus: Equatable, Sendable {
    let provider: SigningProviderID
    let state: SigningProviderState
    let detail: String
    let checkedAt: Date?
}

struct SigningProviderOffering: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let detail: String
    let status: String
}

protocol SigningProviderAdapting: Sendable {
    static var descriptor: SigningProviderDescriptor { get }
    func status() async throws -> SigningProviderStatus
    func offerings() async throws -> [SigningProviderOffering]
    func cancel()
    func disconnect() async throws
}

enum SigningProviderError: Error, LocalizedError, Equatable {
    case unsupported(SigningProviderID)
    case rateLimited(retryAfterSeconds: TimeInterval?)
    case cancelled
    case malformedResponse
    case networkFailure

    var errorDescription: String? {
        switch self {
        case .unsupported(let provider):
            return String.localized("%@ is not enabled in this build. No credentials were requested.", arguments: provider.rawValue)
        case .rateLimited:
            return .localized("The provider rate-limited this request. VexSign stopped instead of retrying indefinitely.")
        case .cancelled:
            return .localized("The provider request was cancelled. No certificate was changed.")
        case .malformedResponse:
            return .localized("The provider response could not be verified. Nothing was imported.")
        case .networkFailure:
            return .localized("The provider could not be reached. Existing valid identities were kept.")
        }
    }
}

/// Only idempotent reads are retried, at most twice, with a capped delay.
/// Download/import operations are never retried here: they can consume quota
/// or leave ambiguous server state.
struct ProviderRetryPolicy: Equatable, Sendable {
    let maximumAttempts: Int
    let maximumDelay: TimeInterval

    func delay(for attempt: Int, retryAfter: TimeInterval?) -> TimeInterval? {
        guard attempt < maximumAttempts else { return nil }
        let requested = retryAfter ?? 0.5
        guard requested.isFinite else { return min(maximumDelay, 0.5) }
        return min(max(max(requested, 0), 0.25), maximumDelay)
    }
}

enum SigningProviderRegistry {
    static let descriptors: [SigningProviderID: SigningProviderDescriptor] = [
        .appleDeveloper: .init(
            id: .appleDeveloper,
            displayName: "Apple Developer",
            capabilities: [.certificateList, .profileDownload, .statusCheck, .accountStatus],
            limitations: [
                "Apple Account authentication stays in NativeSigning. This build does not expose paid portal provisioning.",
                "An individual/organization team label is not treated as verified paid enrollment."
            ],
            sourceHost: nil,
            requiresExplicitDisclosure: false),
        .localCertificateFiles: .init(
            id: .localCertificateFiles,
            displayName: "Certificate Files",
            capabilities: [.statusCheck],
            limitations: [
                "Reads only user-selected PKCS#12 and provisioning-profile files.",
                "No account, token or remote API is involved."
            ],
            sourceHost: nil,
            requiresExplicitDisclosure: false),
        .communityNexCerts: .init(
            id: .communityNexCerts,
            displayName: "Community Certificates (Unofficial)",
            capabilities: [.certificateList, .certificateDownload, .profileDownload, .statusCheck],
            limitations: [
                "Third-party shared identities; the certificate password is published by the same host.",
                "No account authentication, no remote signing, and no revocation guarantee.",
                "Certificate type is unknown until the downloaded files are validated locally."
            ],
            sourceHost: NexCerts.sourceHost,
            requiresExplicitDisclosure: true)
    ]

    /// Unsupported providers must be named as unsupported rather than silently
    /// falling through to a generic client.
    static func descriptor(for id: SigningProviderID) -> SigningProviderDescriptor? { descriptors[id] }

    static func unsupported(_ id: SigningProviderID) -> SigningProviderError { .unsupported(id) }
}

// MARK: - Credential storage
//
// A provider that later verifies an authenticated API can use this store. It
// deliberately never exports a token into a view model, log or JSON inventory.
// No enabled provider in this build collects an Apple Account password.

struct ProviderCredentialStore {
    let provider: SigningProviderID
    var service: String { "com.vexsign.provider-credentials" }
    var account: String { "provider.\(provider.rawValue).credential" }

    func read(
        reader: (String, String) throws -> Data? = { account, service in
            try SecureSecretStore.read(account, service: service)
        }
    ) throws -> String? {
        guard let data = try reader(account, service) else { return nil }
        guard data.count <= 64 * 1024, let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            throw SigningProviderError.malformedResponse
        }
        return value
    }

    func write(
        _ value: String,
        writer: (Data, String, String) throws -> Void = { data, account, service in
            try SecureSecretStore.write(data, account: account, service: service)
        }
    ) throws {
        guard !value.isEmpty, value.utf8.count <= 64 * 1024 else { throw SigningProviderError.malformedResponse }
        try writer(Data(value.utf8), account, service)
    }

    func delete(
        deleter: (String, String) throws -> Void = { account, service in
            try SecureSecretStore.delete(account, service: service)
        }
    ) throws {
        try deleter(account, service)
    }

    static func redacted(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return .localized("None") }
        return .localized("Stored (hidden)")
    }

    /// Fixed strings only; neither the token nor a prefix of it reaches a log.
    static func redactedState(for error: Error?) -> String {
        guard let error else { return .localized("No stored credential") }
        if error is SigningProviderError { return .localized("Credential unavailable") }
        return .localized("Keychain unavailable")
    }
}
