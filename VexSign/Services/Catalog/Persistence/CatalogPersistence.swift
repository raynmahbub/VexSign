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

    func sources() throws -> [CatalogSourceRecord] {
        try database.read(sourcesKey, as: [CatalogSourceRecord].self) ?? []
    }

    func saveSources(_ sources: [CatalogSourceRecord]) throws {
        guard sources.count <= 512 else { throw CatalogPersistenceError.limitExceeded }
        try database.write(sources, key: sourcesKey)
    }

    func snapshot(sourceID: String) throws -> CatalogSnapshot? {
        try database.read("catalog.snapshot.v1.\(sourceID)", as: CatalogSnapshot.self)
    }

    func saveSnapshot(_ snapshot: CatalogSnapshot) throws {
        // Validate shard shape before committing: a parse result from a failed
        // refresh must never reach the offline cache.
        guard !snapshot.apps.isEmpty || snapshot.diagnostics.isEmpty else {
            throw CatalogPersistenceError.invalidSnapshot
        }
        try database.write(snapshot, key: "catalog.snapshot.v1.\(snapshot.sourceID)")
    }

    func removeSnapshot(sourceID: String) throws {
        try database.delete("catalog.snapshot.v1.\(sourceID)")
    }

    func allSnapshots(sourceIDs: [String]) throws -> [String: CatalogSnapshot] {
        var result: [String: CatalogSnapshot] = [:]
        for id in sourceIDs {
            if let snapshot = try snapshot(sourceID: id), !snapshot.apps.isEmpty { result[id] = snapshot }
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
