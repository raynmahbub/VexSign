import Foundation
import NativeSigning
import NimbleExtensions

/// Encapsulates Anisette provider validation, verification, configuration, and server catalog loading
/// outside SwiftUI views (`AnisetteProviderConfigView`).
@MainActor
final class AnisetteProviderUseCase {
    private let factory: AnisetteProviderFactory
    private let synchronizeManager: () async -> Void
    private let probeDescriptor: (AnisetteProviderDescriptor) async throws -> Void

    init(
        factory: AnisetteProviderFactory = .shared,
        synchronizeManager: @escaping () async -> Void = { await NativeSigningManager.shared.synchronizeProvider() },
        probeDescriptor: @escaping (AnisetteProviderDescriptor) async throws -> Void = { descriptor in
            if descriptor.protocolKind == .v3 {
                let provider = try NativeV3AnisetteProvider(descriptor: descriptor)
                _ = try await provider.freshHeaders()
            } else {
                let provider = try HTTPSAnisetteProvider<SystemAnisetteHeaderTransport>(descriptor: descriptor)
                _ = try await provider.freshHeaders()
            }
        }
    ) {
        self.factory = factory
        self.synchronizeManager = synchronizeManager
        self.probeDescriptor = probeDescriptor
    }

    func validateEndpoint(_ raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else {
            throw URLError(.badURL)
        }
        guard url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty else {
            throw ArchitectureDomainError.insecureTransport("Endpoint must use HTTPS")
        }
        return url
    }

    func loadBundledCatalog() throws -> AnisetteServerCatalog {
        try AnisetteServerCatalog.bundled()
    }

    func saveConfiguration(
        endpoint: String,
        identity: String,
        displayName: String,
        policyRevision: String,
        protocolKind: AnisetteProviderDescriptor.ProtocolKind,
        verifyBeforeSaving: Bool
    ) async throws {
        let url = try validateEndpoint(endpoint)
        if verifyBeforeSaving {
            let descriptor = try AnisetteProviderDescriptor(
                identifier: identity,
                displayName: displayName,
                policyRevision: policyRevision,
                endpoint: url,
                protocolKind: protocolKind
            )
            try await probeDescriptor(descriptor)
        }
        try Task.checkCancellation()
        try factory.configureHTTPS(
            endpoint: url,
            identity: identity,
            displayName: displayName,
            policyRevision: policyRevision,
            protocolKind: protocolKind
        )
        await synchronizeManager()
    }

    func testCurrentProvider() async throws {
        guard let descriptor = factory.currentDescriptor else {
            throw ArchitectureDomainError.invalidURL("No Anisette provider configured.")
        }
        try await probeDescriptor(descriptor)
    }

    func clearConfiguration() async {
        factory.clearConfiguration()
        await synchronizeManager()
    }
}
