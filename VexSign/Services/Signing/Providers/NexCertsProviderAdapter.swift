// MARK: - Community NexCerts provider adapter
//
// A provider-specific adapter over the already-verified public catalogue
// workflow. It does not invent endpoints, does not ask for an Apple Account
// password and does not claim that shared certificates are private or trusted.

import Foundation

actor NexCertsProviderAdapter: SigningProviderAdapting {
    static let descriptor = SigningProviderRegistry.descriptors[.communityNexCerts]!

    private let attempts: Int
    private let defaults: UserDefaults
    private let load: (() async throws -> [NexCerts.CatalogItem])?
    private let sleep: (TimeInterval) async throws -> Void
    private var cancelled = false
    private var activeTask: Task<Void, Error>?
    private var catalog: [NexCerts.CatalogItem] = []
    private var lastOfferings: [SigningProviderOffering] = []

    init(
        attempts: Int = 2,
        defaults: UserDefaults = .standard,
        load: (() async throws -> [NexCerts.CatalogItem])? = nil,
        sleep: @escaping (TimeInterval) async throws -> Void = { interval in
            try await Task.sleep(nanoseconds: UInt64(max(0, interval) * 1_000_000_000))
        }
    ) {
        self.attempts = attempts
        self.defaults = defaults
        self.load = load
        self.sleep = sleep
    }

    func status() async throws -> SigningProviderStatus {
        try Task.checkCancellation()
        guard !cancelled else { throw SigningProviderError.cancelled }
        let acknowledged = NexCertsAccess.hasAcknowledged(defaults)
        return SigningProviderStatus(
            provider: .communityNexCerts,
            state: acknowledged ? .available : .notConfigured,
            detail: acknowledged
                ? "Unofficial source acknowledged; catalogue listings require a fresh fetch."
                : "The user has not acknowledged this unofficial source.",
            checkedAt: Date()
        )
    }

    func offerings() async throws -> [SigningProviderOffering] {
        try Task.checkCancellation()
        guard !cancelled else { throw SigningProviderError.cancelled }
        let task = Task<Void, Error> {
            try Task.checkCancellation()
            let sections = try await NexCerts.fetchCatalog(
                attempts: attempts,
                load: load ?? { try await NexCerts.catalogFromAPI() },
                sleep: sleep
            )
            try Task.checkCancellation()
            catalog = sections.flatMap(\.certificates)
            lastOfferings = catalog.map { item in
                SigningProviderOffering(
                    id: String(item.id),
                    title: item.name,
                    detail: "Provider status: \(item.status.title). Type is unknown until local validation.",
                    status: item.status.title
                )
            }
        }
        activeTask = task
        do {
            try await task.value
        } catch {
            throw Self.translate(error)
        }
        return lastOfferings
    }

    func cancel() {
        cancelled = true
        activeTask?.cancel()
    }

    func disconnect() async throws {
        try Task.checkCancellation()
        NexCertsAccess.revoke(defaults)
        catalog.removeAll()
    }

    /// Downloads are deliberately one-shot: a retry can consume a limited
    /// resource or leave an ambiguous remote state. Uses the exact catalogue
    /// row returned by the last listing, never a reconstructed item.
    func importOffering(id: String) async throws {
        try Task.checkCancellation()
        guard !cancelled else { throw SigningProviderError.cancelled }
        guard let item = catalog.first(where: { String($0.id) == id }) else {
            throw SigningProviderError.malformedResponse
        }
        let task = Task<Void, Error> {
            try Task.checkCancellation()
            try await NexCerts.importCertificate(item)
        }
        activeTask = task
        do {
            try await task.value
        } catch {
            throw Self.translate(error)
        }
    }

    nonisolated static func translate(_ error: Error) -> SigningProviderError {
        if error is CancellationError { return .cancelled }
        guard let nex = error as? NexCertsError else { return .networkFailure }
        switch nex {
        case .rateLimited(let retryAfter): return .rateLimited(retryAfterSeconds: retryAfter)
        case .invalidJSON, .invalidResponse: return .malformedResponse
        default: return .networkFailure
        }
    }
}
