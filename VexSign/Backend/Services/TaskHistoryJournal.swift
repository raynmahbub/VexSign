import Foundation

/// All reads, encoding and atomic replacements run on one FIFO queue. An
/// unreadable original is never treated as an empty journal eligible for writes.
actor TaskHistoryJournal {
    enum Issue: String, Sendable {
        case inaccessible, corruptPreserved, preservationFailed, writeFailed, notLoaded
    }
    enum LoadResult: Sendable {
        case loaded([UnifiedTask.Snapshot], warning: Issue?)
        case blocked(Issue)
    }
    struct IO: Sendable {
        var read: @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }
        var write: @Sendable (Data, URL) throws -> Void = { data, url in
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        var preserve: @Sendable (URL) throws -> Void = { url in
            var backup = url.deletingLastPathComponent().appendingPathComponent("TaskHistory-recovery-\(UUID().uuidString).json")
            // Copy and finish backup policy before removing the only original.
            try FileManager.default.copyItem(at: url, to: backup)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: backup.path)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try backup.setResourceValues(values)
            try FileManager.default.removeItem(at: url)
        }
    }
    private let url: URL
    private let io: IO
    private var writable = false

    init(url: URL, io: IO = IO()) {
        self.url = url
        self.io = io
    }

    func load() async -> LoadResult {
        writable = false
        let data: Data
        do { data = try io.read(url) }
        catch {
            let error = error as NSError
            if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
                writable = true
                return .loaded([], warning: nil)
            } else {
                // Includes protected-data lock, permissions and transient IO;
                // none of these is evidence of malformed JSON.
                return .blocked(.inaccessible)
            }
        }
        do {
            let snapshots = try JSONDecoder().decode([UnifiedTask.Snapshot].self, from: data)
            writable = true
            return .loaded(snapshots, warning: nil)
        } catch {
            do {
                try io.preserve(url)
                writable = true
                return .loaded([], warning: .corruptPreserved)
            } catch {
                return .blocked(.preservationFailed)
            }
        }
    }

    func save(_ snapshots: [UnifiedTask.Snapshot]) async -> Issue? {
        guard writable else { return .notLoaded }
        do {
            let data = try JSONEncoder().encode(snapshots)
            try io.write(data, url)
            return nil
        } catch {
            return .writeFailed
        }
    }
}