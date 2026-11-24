import Foundation

/// Application policy depends on a Domain port, never NativeSigning, a global
/// factory, UserDefaults, or a concrete HTTP implementation.
@MainActor
final class AnisetteProviderUseCase {
    private let provider: AnisetteConfigurationProviding

    init(provider: AnisetteConfigurationProviding) {
        self.provider = provider
    }

    var currentConfiguration: AnisetteConfiguration? { provider.currentConfiguration }

    func validateEndpoint(_ raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else {
            throw ArchitectureDomainError.invalidURL(trimmed)
        }
        guard url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw ArchitectureDomainError.insecureTransport("Endpoint must use HTTPS without credentials, query, or fragment")
        }
        return url
    }

    func loadBundledCatalog() throws -> AnisetteServerCatalog {
        try provider.loadBundledCatalog()
    }

    func saveConfiguration(
        endpoint: String,
        identity: String,
        displayName: String,
        policyRevision: String,
        protocolKind: AnisetteProtocolKind,
        verifyBeforeSaving: Bool
    ) async throws {
        let url = try validateEndpoint(endpoint)
        let configuration = AnisetteConfiguration(
            identifier: identity, displayName: displayName, policyRevision: policyRevision,
            endpoint: url, protocolKind: protocolKind
        )
        if verifyBeforeSaving { try await provider.probe(configuration) }
        try Task.checkCancellation()
        try provider.save(configuration)
        await provider.synchronize()
    }

    func testCurrentProvider() async throws {
        guard let configuration = provider.currentConfiguration else {
            throw ArchitectureDomainError.invalidURL("No Anisette provider configured.")
        }
        try await provider.probe(configuration)
    }

    func clearConfiguration() async {
        provider.clear()
        await provider.synchronize()
    }
}
