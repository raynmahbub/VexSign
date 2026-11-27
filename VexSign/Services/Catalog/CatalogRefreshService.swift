// MARK: - Bounded source refresh
//
// Fetches one source, validates it with a versioned parser, and publishes only
// a fully validated snapshot. The last known good catalog is never replaced by
// a failed or malformed response. Refresh progress is reported to the existing
// task center under its own task kind.

import Foundation
import OSLog
import NimbleExtensions
import NimbleJSON

actor CatalogRefreshService {
    typealias Fetcher = @Sendable (URL, [String: String]) async -> Result<Data, Error>

    private let fetcher: Fetcher
    private let registry: CatalogSourceRegistry
    private let persistence: CatalogPersistence
    private let maximumAttempts: Int

    init(
        fetcher: @escaping Fetcher,
        registry: CatalogSourceRegistry = CatalogSourceRegistry(),
        persistence: CatalogPersistence = CatalogPersistence(),
        maximumAttempts: Int = 2
    ) {
        self.fetcher = fetcher
        self.registry = registry
        self.persistence = persistence
        self.maximumAttempts = max(1, min(3, maximumAttempts))
    }

    /// Production fetcher: the same bounded transport used by the existing source loader.
    static func liveFetcher() -> Fetcher {
        { url, headers in
            let service = NBFetchService()
            return await withCheckedContinuation { continuation in
                service.fetchRaw(from: url, headers: headers) { result in
                    continuation.resume(returning: result)
                }
            }
        }
    }

    /// Fetches and validates a feed without persisting a source or catalog.
    /// Used by the Add Source workflow: a reachable URL is not enough to create
    /// a configured source.
    func preview(address: String, format: CatalogSourceFormat) async throws -> CatalogSnapshot {
        let cleaned = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = cleaned.lowercased().hasPrefix("http://") || cleaned.lowercased().hasPrefix("https://")
            ? cleaned : "https://" + cleaned
        guard let url = URL(string: normalized), url.host != nil else {
            throw CatalogSourceError.invalidURL(.localized("Enter a repository URL with a host."))
        }
        try SourceURLPolicy.validate(url)
        let id = CatalogSourceRegistry.identifier(for: url)
        let requestURL = GitHubReleaseSource.apiURL(for: url) ?? url
        let headers = GitHubReleaseSource.isGitHubRepositoryURL(url) ? [:] : VexSignAPI.authHeaders(for: url)
        switch await fetcher(requestURL, headers) {
        case .failure(let error):
            throw CatalogSourceError.invalidURL(error.localizedDescription)
        case .success(let payload):
            guard !payload.isEmpty, payload.count <= CatalogFeedParser.maximumFeedBytes else {
                throw CatalogParseError.tooLarge
            }
            let feed: Data
            if GitHubReleaseSource.isGitHubRepositoryURL(url) {
                feed = try GitHubReleaseSource.feedPayload(from: payload, sourceURL: url)
            } else { feed = payload }
            let provenance = SourceProvenanceVerifier.evaluate(feed)
            guard provenance.isAcceptable else {
                throw CatalogParseError.invalid(
                    provenance.badgeTitle ?? .localized("The source signature is invalid."), []
                )
            }
            return try CatalogFeedParser.parse(
                feed, sourceID: id, sourceURL: url.absoluteString, format: format
            )
        }
    }

    func refresh(sourceID: String) async throws -> CatalogRefreshOutcome {
        guard let source = try await registry.all().first(where: { $0.id == sourceID }) else {
            throw CatalogSourceError.missingSource
        }
        guard source.enabled else { throw CatalogSourceError.metadataInvalid(.localized("This source is disabled.")) }
        guard let url = URL(string: source.url) else { throw CatalogSourceError.invalidURL(source.url) }
        try SourceURLPolicy.validate(url)

        let taskID = await UnifiedTaskCenter.shared.beginTaskID(
            kind: .sourceRefresh,
            title: source.name,
            subtitle: .localized("Refreshing source"),
            subjectID: source.id
        )
        await UnifiedTaskCenter.shared.transitionTask(id: taskID, to: .downloading, progress: 0.1)

        let started = Date()
        var lastError: String = .localized("The source could not be refreshed.")
        var category: CatalogFailureCategory = .http
        var outcome: CatalogRefreshOutcome?

        attemptLoop: for attempt in 1...maximumAttempts {
            try Task.checkCancellation()
            await UnifiedTaskCenter.shared.updateTask(id: taskID, progress: Double(attempt) / Double(maximumAttempts + 1) * 0.8)
            let requestURL = GitHubReleaseSource.apiURL(for: url) ?? url
            let headers = GitHubReleaseSource.isGitHubRepositoryURL(url) ? [:] : VexSignAPI.authHeaders(for: url)
            switch await fetcher(requestURL, headers) {
            case .failure(let error):
                lastError = error.localizedDescription
                category = Self.isRateLimited(error) ? .rateLimited : .http
                if Self.isRateLimited(error) { break attemptLoop }
                continue
            case .success(let payload):
                guard !payload.isEmpty else {
                    lastError = .localized("The source returned an empty catalog.")
                    category = .parse
                    continue
                }
                guard payload.count <= CatalogFeedParser.maximumFeedBytes else {
                    lastError = .localized("The source catalog exceeds the 16 MB safety limit.")
                    category = .parse
                    break attemptLoop
                }
                let feed: Data
                if GitHubReleaseSource.isGitHubRepositoryURL(url) {
                    do { feed = try GitHubReleaseSource.feedPayload(from: payload, sourceURL: url) }
                    catch {
                        lastError = error.localizedDescription
                        category = .parse
                        continue
                    }
                } else { feed = payload }

                let provenance = SourceProvenanceVerifier.evaluate(feed)
                if case .claimedButInvalid(let reason) = provenance {
                    lastError = reason
                    category = .parse
                    break attemptLoop
                }

                do {
                    let snapshot = try CatalogFeedParser.parse(
                        feed, sourceID: source.id, sourceURL: source.url, format: source.format
                    )
                    let verified: Bool
                    switch provenance {
                    case .verified: verified = true
                    case .unsigned, .claimedButInvalid: verified = false
                    }
                    outcome = .verified(snapshot, integrityVerified: verified)
                    break attemptLoop
                } catch let error as CatalogParseError {
                    lastError = error.localizedDescription
                    if case .unsupportedSchema = error { category = .schema }
                    else { category = .parse }
                    break attemptLoop
                } catch {
                    lastError = error.localizedDescription
                    category = .parse
                    break attemptLoop
                }
            }
        }

        let duration = Date().timeIntervalSince(started)
        let finalOutcome = outcome ?? .failed(lastError, category)
        let updated = try await registry.recordRefresh(
            id: source.id, outcome: finalOutcome, duration: duration, statusCode: nil
        )
        if case .failed = finalOutcome {
            await UnifiedTaskCenter.shared.transitionTask(id: taskID, to: .failed, error: lastError)
        } else {
            await UnifiedTaskCenter.shared.transitionTask(id: taskID, to: .completed, progress: 1)
        }
        if updated.health.consecutiveFailures > 0 {
            Logger.misc.warning("Source refresh kept last-known-good catalog: \(source.id, privacy: .public)")
        }
        return finalOutcome
    }

    func refreshAll() async -> [String: CatalogRefreshOutcome] {
        let sources: [CatalogSourceRecord]
        do { sources = try await registry.all() }
        catch {
            Logger.misc.error("Unable to list sources for refresh: \(error.localizedDescription, privacy: .public)")
            return [:]
        }
        var results: [String: CatalogRefreshOutcome] = [:]
        for source in sources where source.enabled {
            do { results[source.id] = try await refresh(sourceID: source.id) }
            catch {
                results[source.id] = .failed(
                    error.localizedDescription,
                    Self.isRateLimited(error) ? .rateLimited : .http
                )
            }
        }
        return results
    }

    private static func isRateLimited(_ error: Error) -> Bool {
        guard case NBFetchService.NBFetchServiceError.httpError(429) = error else { return false }
        return true
    }
}
