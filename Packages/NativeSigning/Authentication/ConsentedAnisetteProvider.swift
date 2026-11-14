import Foundation
import SideSign

public enum AnisetteConsentError: Error, Equatable {
    case invalidProvider
    case invalidLifetime
    case consentRequired
    case providerChanged
    case providerFailed
}

/// UI must display this identity/policy/endpoint before asking for consent. No
/// default server is supplied. Remote endpoints require HTTPS and cannot embed
/// credentials, query secrets or fragments. Nil endpoint denotes on-device work.
public struct AnisetteProviderDescriptor: Equatable, Sendable {
    public enum ProtocolKind: String, Codable, CaseIterable, Sendable { case headers, v3 }
    public let protocolKind: ProtocolKind
    public let identifier: String
    public let displayName: String
    public let policyRevision: String
    public let endpoint: URL?

    public init(identifier: String, displayName: String, policyRevision: String, endpoint: URL?, protocolKind: ProtocolKind = .headers) throws {
        let strings = [identifier, displayName, policyRevision]
        guard strings.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && $0.utf8.count <= 256
            && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }) else {
            throw AnisetteConsentError.invalidProvider
        }
        if let endpoint {
            guard endpoint.scheme?.lowercased() == "https", let host = endpoint.host, !host.isEmpty,
                  endpoint.user == nil, endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil else {
                throw AnisetteConsentError.invalidProvider
            }
        }
        if protocolKind == .v3, endpoint == nil { throw AnisetteConsentError.invalidProvider }
        self.protocolKind = protocolKind
        self.identifier = identifier
        self.displayName = displayName
        self.policyRevision = policyRevision
        self.endpoint = endpoint
    }
}

/// Deliberately receives no Apple ID, password, portal token or 2FA response.
/// Implementations still require independent transport/storage/privacy review;
/// this protocol cannot stop malicious native code with host-process authority.
public protocol ConsentedAnisetteProvider: Sendable {
    var descriptor: AnisetteProviderDescriptor { get }
    func freshHeaders() async throws -> AnisetteData
}

public struct AnisetteConsentToken: Equatable, Sendable {
    let id: UUID
    let provider: AnisetteProviderDescriptor
    let expiresAt: Date
}

/// In-memory grant only. Not Codable; no preferences, automatic renewal or
/// startup grant. The future UI must call recordExplicitConsent only after an
/// informed user action. The type cannot independently prove that action occurred.
struct AnisetteConsentGate: Sendable {
    private var active: AnisetteConsentToken?

    mutating func recordExplicitConsent(for provider: AnisetteProviderDescriptor, now: Date,
                                        lifetime: TimeInterval = 900) throws -> AnisetteConsentToken {
        guard now.timeIntervalSince1970.isFinite, lifetime.isFinite, lifetime > 0, lifetime <= 900 else {
            throw AnisetteConsentError.invalidLifetime
        }
        let token = AnisetteConsentToken(id: UUID(), provider: provider, expiresAt: now.addingTimeInterval(lifetime))
        active = token
        return token
    }

    func require(_ token: AnisetteConsentToken, provider: AnisetteProviderDescriptor, now: Date) throws {
        guard token.provider == provider else { throw AnisetteConsentError.providerChanged }
        guard active == token, now.timeIntervalSince1970.isFinite, token.expiresAt > now else {
            throw AnisetteConsentError.consentRequired
        }
    }

    mutating func revoke() { active = nil }
}
