// MARK: - Source registration and metadata
//
// The Core Data `AltSource` row remains the canonical configured source. This
// registry stores only catalog-specific metadata (format, schema, validation,
// health) keyed by the same stable id, so there is no second source list to
// keep in sync. URL policy and duplicate detection are enforced here before
// anything is persisted.

import Foundation
import NimbleExtensions

enum CatalogSourceError: LocalizedError, Equatable {
    case duplicateSource
    case invalidURL(String)
    case missingSource
    case metadataInvalid(String)

    var errorDescription: String? {
        switch self {
        case .duplicateSource: .localized("This repository is already configured.")
        case .invalidURL(let detail): String.localized("The repository URL is invalid: %@", arguments: detail)
        case .missingSource: .localized("That repository is no longer configured.")
        case .metadataInvalid(let detail): String.localized("The source metadata is invalid: %@", arguments: detail)
        }
    }
}

actor CatalogSourceRegistry {
    private let persistence: CatalogPersistence

    init(persistence: CatalogPersistence = CatalogPersistence()) {
        self.persistence = persistence
    }

    func all() async throws -> [CatalogSourceRecord] {
        try await persistence.sources().sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Reconciles the metadata store with configured sources. Deleted sources
    /// lose their snapshot; newly added ones get an unverified record without
    /// making any network request.
    func reconcile(configured: [RepositoryRecord]) async throws -> [CatalogSourceRecord] {
        let saved = try await persistence.sources()
        var byID = Dictionary(saved.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [CatalogSourceRecord] = []
        var retained: Set<String> = []

        for record in configured {
            let url = record.sourceURL?.absoluteString ?? ""
            let declared = record.identifier
            // Core Data identifiers come from the feed declaration while a newly
            // registered catalog source is keyed by its address. Both must map
            // to one metadata row, otherwise refresh and search drift apart.
            let match = byID[Self.id(for: record)]
                ?? saved.first { item in
                    (declared.map { !$0.isEmpty && item.declaredIdentifier == $0 } ?? false)
                        || (!url.isEmpty && CatalogIdentity.isSameSource(item.url, url))
                }
            let id = match?.id ?? Self.id(for: record)
            if let match { byID.removeValue(forKey: match.id) }
            retained.insert(id)

            var item = match ?? CatalogSourceRecord(
                id: id, declaredIdentifier: declared,
                name: record.name ?? url, url: url, createdAt: record.date ?? Date()
            )
            if let match,
               CatalogIdentity.sourceKey(match.url) != CatalogIdentity.sourceKey(url) {
                // The canonical source row moved. Bytes from the old address belong
                // to a different feed and must not be served under the new one.
                try await persistence.removeSnapshot(sourceID: id)
                item.validationState = .unverified
                item.integrityVerified = false
                item.schemaVersion = nil
                item.applicationCount = 0
            }
            item.declaredIdentifier = declared
            item.name = record.name ?? item.name
            item.url = url
            result.append(item)
        }

        for removed in byID.keys {
            try await persistence.removeSnapshot(sourceID: removed)
        }
        try await persistence.saveSources(result)
        return result
    }

    func add(
        url: URL,
        name: String,
        format: CatalogSourceFormat = .altStore,
        declaredIdentifier: String? = nil
    ) async throws -> CatalogSourceRecord {
        do { try SourceURLPolicy.validate(url) }
        catch { throw CatalogSourceError.invalidURL(error.localizedDescription) }
        let id = Self.identifier(for: url)
        let known = try await persistence.sources()
        if known.contains(where: { $0.id == id }) || known.contains(where: {
            CatalogIdentity.isSameSource($0.url, url.absoluteString)
        }) {
            throw CatalogSourceError.duplicateSource
        }
        let now = Date()
        let source = CatalogSourceRecord(
            id: id,
            declaredIdentifier: declaredIdentifier,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? url.host ?? name : name,
            url: url.absoluteString,
            format: format,
            createdAt: now,
            updatedAt: now
        )
        try await persistence.saveSources(known + [source])
        return source
    }

    func update(
        id: String,
        name: String? = nil,
        summary: String? = nil,
        artworkURL: String? = nil,
        format: CatalogSourceFormat? = nil
    ) async throws -> CatalogSourceRecord {
        var sources = try await persistence.sources()
        guard let index = sources.firstIndex(where: { $0.id == id }) else { throw CatalogSourceError.missingSource }
        if let artworkURL, !artworkURL.isEmpty,
           RepositoryValidator.webURL(artworkURL) == nil {
            throw CatalogSourceError.metadataInvalid(.localized("Artwork must be an absolute HTTP(S) URL."))
        }
        if let name, name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw CatalogSourceError.metadataInvalid(.localized("A source needs a display name."))
        }
        sources[index].name = name ?? sources[index].name
        sources[index].summary = summary
        sources[index].artworkURL = artworkURL
        sources[index].format = format ?? sources[index].format
        sources[index].updatedAt = Date()
        try await persistence.saveSources(sources)
        return sources[index]
    }

    /// Changes the address of an existing source without duplicating it. The
    /// snapshot is dropped because its contents belong to the old address.
    func changeURL(id: String, to url: URL) async throws -> CatalogSourceRecord {
        do { try SourceURLPolicy.validate(url) }
        catch { throw CatalogSourceError.invalidURL(error.localizedDescription) }
        var sources = try await persistence.sources()
        guard let index = sources.firstIndex(where: { $0.id == id }) else { throw CatalogSourceError.missingSource }
        if sources.contains(where: { $0.id != id && CatalogIdentity.isSameSource($0.url, url.absoluteString) }) {
            throw CatalogSourceError.duplicateSource
        }
        sources[index].url = url.absoluteString
        sources[index].validationState = .unverified
        sources[index].updatedAt = Date()
        try await persistence.saveSources(sources)
        try await persistence.removeSnapshot(sourceID: id)
        return sources[index]
    }

    func setEnabled(id: String, enabled: Bool) async throws -> CatalogSourceRecord {
        var sources = try await persistence.sources()
        guard let index = sources.firstIndex(where: { $0.id == id }) else { throw CatalogSourceError.missingSource }
        sources[index].enabled = enabled
        sources[index].updatedAt = Date()
        try await persistence.saveSources(sources)
        return sources[index]
    }

    func remove(id: String) async throws {
        var sources = try await persistence.sources()
        guard let index = sources.firstIndex(where: { $0.id == id }) else { throw CatalogSourceError.missingSource }
        sources.remove(at: index)
        try await persistence.saveSources(sources)
        try await persistence.removeSnapshot(sourceID: id)
    }

    /// Applies one refresh outcome. Only a fully parsed snapshot can mark a
    /// source valid; an HTTP 200 with a broken catalog is a parse failure.
    func recordRefresh(
        id: String,
        outcome: CatalogRefreshOutcome,
        duration: TimeInterval,
        statusCode: Int?
    ) async throws -> CatalogSourceRecord {
        var sources = try await persistence.sources()
        guard let index = sources.firstIndex(where: { $0.id == id }) else { throw CatalogSourceError.missingSource }
        let now = Date()
        var health = sources[index].health
        health.lastRefreshDuration = duration
        health.lastStatusCode = statusCode

        switch outcome {
        case .verified(let snapshot, let integrityVerified):
            try await persistence.saveSnapshot(snapshot)
            health.lastSuccessfulRefresh = now
            health.lastError = nil
            health.consecutiveFailures = 0
            // A successfully parsed unsigned feed is usable but not trusted;
            // "stale" would falsely imply the catalog itself failed validation.
            sources[index].validationState = integrityVerified ? .valid : .unverified
            sources[index].integrityVerified = integrityVerified
            sources[index].schemaVersion = snapshot.schemaVersion
            sources[index].applicationCount = snapshot.apps.count
            sources[index].name = snapshot.name ?? sources[index].name
            sources[index].summary = snapshot.summary
            sources[index].artworkURL = snapshot.artworkURL
        case .unchanged(let snapshot):
            // Conditional 304: keep the cached bytes, only refresh freshness.
            try await persistence.saveSnapshot(snapshot)
            health.lastSuccessfulRefresh = now
            health.lastError = nil
            health.consecutiveFailures = 0
            sources[index].validationState = .valid
        case .failed(let detail, let category):
            health.lastFailedRefresh = now
            health.lastError = detail
            health.consecutiveFailures += 1
            switch category {
            case .http, .rateLimited: health.httpFailures += 1
            case .parse: health.parseFailures += 1
            case .schema: health.schemaFailures += 1
            }
            sources[index].validationState = category == .schema ? .unsupportedSchema : .invalid
        }
        sources[index].health = health
        sources[index].updatedAt = now
        try await persistence.saveSources(sources)
        return sources[index]
    }

    static func id(for record: RepositoryRecord) -> String {
        record.identifier ?? record.sourceURL.map(identifier(for:)) ?? record.id
    }

    static func identifier(for url: URL) -> String {
        CatalogIdentity.sourceKey(url.absoluteString) ?? url.absoluteString
    }
}

enum CatalogRefreshOutcome: Sendable {
    case verified(CatalogSnapshot, integrityVerified: Bool)
    case unchanged(CatalogSnapshot)
    case failed(String, CatalogFailureCategory)
}

enum CatalogFailureCategory: String, Sendable {
    case http
    case rateLimited
    case parse
    case schema
}
