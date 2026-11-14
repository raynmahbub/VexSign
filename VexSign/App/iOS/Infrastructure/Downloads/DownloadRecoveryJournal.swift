import Foundation

/// Atomic checkpoints, not permission to replay an interrupted database commit.
/// URLs with credentials/query tokens are deliberately not persisted.
struct DownloadRecoveryJournal {
    enum Stage: String, Codable { case downloading, verifying, awaitingDecision, importing, committing, committed }
    struct Record: Codable, Identifiable {
        let id: UUID
        let name: String
        let sourceURL: URL?
        let expectedBytes: Int64?
        let expectedHash: String?
        var stage: Stage
        var stagedName: String?
        var updatedAt: Date
        var libraryUUID: String? = nil

        var canReverify: Bool { stage == .verifying || stage == .awaitingDecision }
    }
    let root: URL

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DownloadRecovery", isDirectory: true)
    }

    static func publicURL(_ url: URL) -> URL? {
        guard url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { return nil }
        return url
    }

    func save(_ record: Record) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try validate(record)
        let data = try JSONEncoder().encode(record)
        guard data.count <= 32 * 1024 else { throw CocoaError(.fileWriteOutOfSpace) }
        try data.write(to: root.appendingPathComponent(record.id.uuidString + ".json"),
                       options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Opaque system resume blobs are bounded, protected and excluded from backups.
    /// A blob is offered only when its original URL agrees with the journal's public URL.
    func saveResumeData(_ data: Data, id: UUID, source: URL) throws {
        guard data.count <= 8 * 1024 * 1024, Self.publicURL(source) != nil else { return }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var path = root.appendingPathComponent(id.uuidString + ".resume")
        try data.write(to: path, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try path.setResourceValues(values)
    }

    func resumeData(id: UUID, source: URL) throws -> Data? {
        guard Self.publicURL(source) != nil else { return nil }
        let path = root.appendingPathComponent(id.uuidString + ".resume")
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let values = try path.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              (values.fileSize ?? Int.max) <= 8 * 1024 * 1024 else { return nil }
        let data = try Data(contentsOf: path)
        // Unknown/new opaque formats safely fall back to an ordinary download.
        let plist: [String: Any]?
        do { plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] }
        catch { return nil } // Unknown/corrupt system formats require a fresh request, never a guessed resume.
        guard let original = plist?["NSURLSessionDownloadInfoURL"] as? String,
              URL(string: original) == source else { return nil }
        return data
    }

    func remove(_ id: UUID) throws {
        let path = root.appendingPathComponent(id.uuidString + ".json")
        if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
        let resume = root.appendingPathComponent(id.uuidString + ".resume")
        if FileManager.default.fileExists(atPath: resume.path) { try FileManager.default.removeItem(at: resume) }
    }

    func load() throws -> [Record] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard files.count <= 1000 else { throw CocoaError(.fileReadCorruptFile) }
        return try files.filter { $0.pathExtension == "json" }.map { file in
            let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  (values.fileSize ?? Int.max) <= 32 * 1024 else { throw CocoaError(.fileReadCorruptFile) }
            let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: file))
            guard file.lastPathComponent == record.id.uuidString + ".json" else { throw CocoaError(.fileReadCorruptFile) }
            try validate(record)
            return record
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Launch cleanup must retain every referenced package; failure to read is not permission to purge.
    func retainedStagingNames() throws -> Set<String> { Set(try load().compactMap(\.stagedName)) }

    private func validate(_ record: Record) throws {
        guard record.name.utf8.count <= 4096,
              record.expectedBytes.map({ $0 >= 0 }) ?? true,
              record.libraryUUID.map({ UUID(uuidString: $0) != nil }) ?? true else { throw CocoaError(.fileReadCorruptFile) }
        if let url = record.sourceURL, Self.publicURL(url) == nil { throw CocoaError(.fileReadCorruptFile) }
        if let name = record.stagedName {
            guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 255,
                  !name.contains("/"), !name.contains("\\"), !name.contains("\0") else { throw CocoaError(.fileReadCorruptFile) }
        }
    }

    /// No arbitrary stored paths, directories, or symlinks can be opened as recovery packages.
    func stagedFile(for record: Record, in staging: URL) -> URL? {
        guard let name = record.stagedName, !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\\"), !name.contains("\0") else { return nil }
        let url = staging.appendingPathComponent(name)
        guard url.resolvingSymlinksInPath().deletingLastPathComponent() == staging.resolvingSymlinksInPath(),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]), // try? ok: inaccessible recovery input is not offered
              values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
        return url
    }
}
