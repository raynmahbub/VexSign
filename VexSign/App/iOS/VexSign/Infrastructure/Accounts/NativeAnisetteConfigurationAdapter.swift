import Foundation
import NativeSigning

/// Owns SDK translation, bundled catalogue I/O, persistence, and provider probes.
/// Application policy sees only the Domain configuration and provider port.
@MainActor
final class NativeAnisetteConfigurationAdapter: AnisetteConfigurationProviding {
    private let factory: AnisetteProviderFactory
    private let bundle: Bundle

    init(factory: AnisetteProviderFactory? = nil, bundle: Bundle = .main) {
        self.factory = factory ?? AnisetteProviderFactory.shared
        self.bundle = bundle
    }

    var currentConfiguration: AnisetteConfiguration? {
        guard let descriptor = factory.currentDescriptor else { return nil }
        return AnisetteConfiguration(
            identifier: descriptor.identifier, displayName: descriptor.displayName,
            policyRevision: descriptor.policyRevision, endpoint: descriptor.endpoint,
            protocolKind: descriptor.protocolKind == .v3 ? .v3 : .headers
        )
    }

    func loadBundledCatalog() throws -> AnisetteServerCatalog {
        try AnisetteServerCatalog.bundled(in: bundle)
    }

    func probe(_ configuration: AnisetteConfiguration) async throws {
        let descriptor = try descriptor(for: configuration)
        if descriptor.protocolKind == .v3 {
            let provider = try NativeV3AnisetteProvider(descriptor: descriptor)
            _ = try await provider.freshHeaders()
        } else {
            let provider = try HTTPSAnisetteProvider<SystemAnisetteHeaderTransport>(descriptor: descriptor)
            _ = try await provider.freshHeaders()
        }
    }

    func save(_ configuration: AnisetteConfiguration) throws {
        let descriptor = try descriptor(for: configuration)
        guard let endpoint = descriptor.endpoint else {
            throw ArchitectureDomainError.invalidURL("An HTTPS endpoint is required.")
        }
        try factory.configureHTTPS(
            endpoint: endpoint, identity: descriptor.identifier,
            displayName: descriptor.displayName, policyRevision: descriptor.policyRevision,
            protocolKind: descriptor.protocolKind
        )
    }

    func clear() { factory.clearConfiguration() }

    func synchronize() async { await NativeSigningManager.shared.synchronizeProvider() }

    private func descriptor(for configuration: AnisetteConfiguration) throws -> AnisetteProviderDescriptor {
        try AnisetteProviderDescriptor(
            identifier: configuration.identifier, displayName: configuration.displayName,
            policyRevision: configuration.policyRevision, endpoint: configuration.endpoint,
            protocolKind: configuration.protocolKind == .v3 ? .v3 : .headers
        )
    }
}
