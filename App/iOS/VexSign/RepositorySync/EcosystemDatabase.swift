import Foundation
import SQLite3

/// A separate, disposable SQLite store; never changes the existing Core Data schema.
/// One actor owns the connection and serializes writes. WAL recovers interrupted commits.
actor EcosystemDatabase {
    static let shared = EcosystemDatabase()
    private var database: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func connection() throws -> OpaquePointer {
        if let database { return database }
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Ecosystem", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                              attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var handle: OpaquePointer?
        guard sqlite3_open_v2(directory.appendingPathComponent("cache.sqlite").path, &handle,
                             SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw RepositoryError.invalid("Unable to open ecosystem cache.")
        }
        sqlite3_busy_timeout(handle, 5_000)
        let schema = "PRAGMA journal_mode=WAL; CREATE TABLE IF NOT EXISTS records (key TEXT PRIMARY KEY, value BLOB NOT NULL); PRAGMA user_version=1;"
        guard sqlite3_exec(handle, schema, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(handle); throw RepositoryError.invalid("Unable to initialize ecosystem cache.")
        }
        database = handle
        return handle
    }
    func read<T: Decodable & Sendable>(_ key: String, as type: T.Type) throws -> T? {
        let db = try connection()
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM records WHERE key=?", -1, &stmt, nil) == SQLITE_OK else { throw failure(db) }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, transient)
        let result = sqlite3_step(stmt)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW, let bytes = sqlite3_column_blob(stmt, 0) else { throw failure(db) }
        return try JSONDecoder().decode(type, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 0))))
    }
    func write<T: Encodable & Sendable>(_ value: T, key: String) throws {
        let data = try JSONEncoder().encode(value)
        let db = try connection()
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO records(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", -1, &stmt, nil) == SQLITE_OK else { throw failure(db) }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, transient)
        let result = data.withUnsafeBytes { bytes -> Int32 in
            sqlite3_bind_blob(stmt, 2, bytes.baseAddress, Int32(data.count), transient)
            return sqlite3_step(stmt)
        }
        guard result == SQLITE_DONE else { throw failure(db) }
    }
    private func failure(_ db: OpaquePointer) -> Error {
        RepositoryError.invalid("Cache error: \(String(cString: sqlite3_errmsg(db)))")
    }
    deinit { if let database { sqlite3_close(database) } }
}
