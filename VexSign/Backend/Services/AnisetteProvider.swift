// MARK: - AnisetteProvider
/// What the app adds around NativeSigning's anisette pieces.
///
/// The HTTPS transport is *not* re-declared here. `NativeSigning` already ships
/// `SystemAnisetteHeaderTransport` — bounded streaming, no cookies or cache, redirects
/// refused — and `HTTPSAnisetteProvider.init(descriptor:)` only exists for that exact
/// transport (`extension HTTPSAnisetteProvider where Transport == SystemAnisetteHeaderTransport`).
/// A same-named app type would shadow it inside this module and leave every
/// `HTTPSAnisetteProvider<SystemAnisetteHeaderTransport>(descriptor:)` call without an
/// initializer, so the dependency's transport is the only one.

import Foundation
import NativeSigning
// `AnisetteData` is SideSign's, reached here through NativeSigning's
// `ConsentedAnisetteProvider.freshHeaders()`. Conforming to that protocol means naming the
// type, so the module has to be imported rather than merely linked.
import SideSign

// MARK: - LocalAnisetteProvider
/// A local/default anisette provider that can be used for testing.
/// In production, users should configure their own HTTPS endpoint.
/// This implementation returns a known-good static response for testing only.

public struct LocalAnisetteProvider: ConsentedAnisetteProvider {
    public let descriptor: AnisetteProviderDescriptor
    private let staticHeaders: AnisetteData?

    public init(descriptor: AnisetteProviderDescriptor, staticHeaders: AnisetteData? = nil) {
        self.descriptor = descriptor
        self.staticHeaders = staticHeaders
    }

    public func freshHeaders() async throws -> AnisetteData {
        // If static headers provided (for testing), return them
        if let headers = staticHeaders {
            return headers
        }
        // Otherwise, require a configured endpoint (handled by HTTPSAnisetteProvider)
        throw HTTPSAnisetteProviderError.remoteEndpointRequired
    }
}

// MARK: - AnisetteProviderFactory
/// Factory for creating configured anisette providers based on user settings.

@MainActor
public final class AnisetteProviderFactory: ObservableObject {
    public static let shared = AnisetteProviderFactory()

    @Published public private(set) var currentDescriptor: AnisetteProviderDescriptor?
    @Published public private(set) var isConfigured = false

    private init() {
        loadSavedConfiguration()
    }

    /// Creates the appropriate provider for the current configuration.
    /// Returns nil if not configured.
    public func makeProvider() -> (any ConsentedAnisetteProvider)? {
        guard let descriptor = currentDescriptor else { return nil }

        // If endpoint is configured, use HTTPS provider
        if descriptor.endpoint != nil {
            do {
                if descriptor.protocolKind == .v3 { return try NativeV3AnisetteProvider(descriptor: descriptor) }
                return try HTTPSAnisetteProvider<SystemAnisetteHeaderTransport>(descriptor: descriptor)
            } catch {
                return nil
            }
        }
        // Otherwise, no default provider available
        return nil
    }

    /// Configures the provider with a custom HTTPS endpoint.
    public func configureHTTPS(endpoint: URL, identity: String = "vexsign.local",
                                displayName: String = "Custom Anisette Server",
                                policyRevision: String = "1",
                                protocolKind: AnisetteProviderDescriptor.ProtocolKind = .headers) throws {
        let descriptor = try AnisetteProviderDescriptor(
            identifier: identity,
            displayName: displayName,
            policyRevision: policyRevision,
            endpoint: endpoint,
            protocolKind: protocolKind
        )
        currentDescriptor = descriptor
        isConfigured = true
        saveConfiguration(descriptor)
    }

    /// Clears the current configuration.
    public func clearConfiguration() {
        currentDescriptor = nil
        isConfigured = false
        UserDefaults.standard.removeObject(forKey: "VexSign.anisetteProvider")
    }

    private func saveConfiguration(_ descriptor: AnisetteProviderDescriptor) {
        let data = try? JSONEncoder().encode(descriptor) // try? ok: encoding known-good Codable struct
        UserDefaults.standard.set(data, forKey: "VexSign.anisetteProvider")
    }

    private func loadSavedConfiguration() {
        guard let data = UserDefaults.standard.data(forKey: "VexSign.anisetteProvider"),
              let descriptor = try? JSONDecoder().decode(AnisetteProviderDescriptor.self, from: data) else { // try? ok: decoding user data, invalid = first run
            return
        }
        currentDescriptor = descriptor
        isConfigured = true
    }
}

// MARK: - AnisetteProviderDescriptor Codable
extension AnisetteProviderDescriptor: @retroactive Codable {
    enum CodingKeys: String, CodingKey {
        case identifier, displayName, policyRevision, endpoint, protocolKind
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolKind, forKey: .protocolKind)
        try container.encode(identifier, forKey: .identifier)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(policyRevision, forKey: .policyRevision)
        try container.encodeIfPresent(endpoint?.absoluteString, forKey: .endpoint)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let identifier = try container.decode(String.self, forKey: .identifier)
        let displayName = try container.decode(String.self, forKey: .displayName)
        let policyRevision = try container.decode(String.self, forKey: .policyRevision)
        let endpointString = try container.decodeIfPresent(String.self, forKey: .endpoint)
        let endpoint = endpointString.flatMap { URL(string: $0) }
        let protocolKind = try container.decodeIfPresent(AnisetteProviderDescriptor.ProtocolKind.self, forKey: .protocolKind) ?? .headers
        try self.init(identifier: identifier, displayName: displayName, policyRevision: policyRevision, endpoint: endpoint, protocolKind: protocolKind)
    }
}

/// Reference data only: catalogue membership is neither trust nor protocol compatibility.
struct AnisetteServerCatalog: Decodable {
    struct Server: Decodable, Identifiable {
        let name: String
        let address: String
        let kind: Int
        var id: String { address }
        var secureEndpoint: URL? {
            guard let url = URL(string: address), url.scheme?.lowercased() == "https",
                  let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
                  url.query == nil, url.fragment == nil else { return nil }
            return url
        }
    }
    let servers: [Server]
    let sourceRepository: String
    let sourceRevision: String
    let reviewedAt: String

    static func bundled(in bundle: Bundle = .main) throws -> Self {
        guard let url = bundle.url(forResource: "AnisetteServers", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}
