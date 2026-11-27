// MARK: - Catalog persistence
//
// Uses the existing `EcosystemDatabase` (WAL SQLite) instead of adding a second
// database. Snapshots are written atomically after validation, so an interrupted
// refresh cannot leave a partially replaced catalog behind.

import Foundation

actor CatalogPersistence {
    private let database: EcosystemDatabase
    private let sourcesKey = "catalog.sources.v1"

    init(database: EcosystemDatabase = .shared) {
        self.database = database
    }

    func sources() async throws -> [CatalogSourceRecord] {
        try await database.read(sourcesKey, as: [CatalogSourceRecord].self) ?? []
    }

    func saveSources(_ sources: [CatalogSourceRecord]) async throws {
        guard sources.count <= 512 else { throw CatalogPersistenceError.limitExceeded }
        try await database.write(sources, key: sourcesKey)
    }

    func snapshot(sourceID: String) async throws -> CatalogSnapshot? {
        try await database.read("catalog.snapshot.v1.\(sourceID)", as: CatalogSnapshot.self)
    }

    func saveSnapshot(_ snapshot: CatalogSnapshot) async throws {
        // Validate shard shape before committing: a parse result from a failed
        // refresh must never reach the offline cache.
        guard !snapshot.apps.isEmpty || snapshot.diagnostics.isEmpty else {
            throw CatalogPersistenceError.invalidSnapshot
        }
        try await database.write(snapshot, key: "catalog.snapshot.v1.\(snapshot.sourceID)")
    }

    func removeSnapshot(sourceID: String) async throws {
        try await database.delete("catalog.snapshot.v1.\(sourceID)")
    }

    func allSnapshots(sourceIDs: [String]) async throws -> [String: CatalogSnapshot] {
        var result: [String: CatalogSnapshot] = [:]
        for id in sourceIDs {
            if let snapshot = try await snapshot(sourceID: id), !snapshot.apps.isEmpty { result[id] = snapshot }
        }
        return result
    }
}

enum CatalogPersistenceError: LocalizedError, Equatable {
    case limitExceeded
    case invalidSnapshot

    var errorDescription: String? {
        switch self {
        case .limitExceeded: "The number of saved sources exceeds the supported limit."
        case .invalidSnapshot: "An incomplete catalog snapshot was refused."
        }
    }
}
