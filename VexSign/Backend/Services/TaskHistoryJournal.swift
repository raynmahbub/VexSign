import Foundation

/// All reads, encoding and atomic replacements run on one FIFO queue. An
/// unreadable original is never treated as an empty journal eligible for writes.
final class TaskHistoryJournal: @unchecked Sendable {
    enum Issue: String {
        case inaccessible, corruptPreserved, preservationFailed, writeFailed, notLoaded
    }
    enum LoadResult {
        case loaded([UnifiedTask.Snapshot], warning: Issue?)
        case blocked(Issue)
    }
    struct IO {
        var read: (URL) throws -> Data = { try Data(contentsOf: $0) }
        var write: (Data, URL) throws -> Void = { data, url in
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        var preserve: (URL) throws -> Void = { url in
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
    private let queue = DispatchQueue(label: "VexSign.task-history", qos: .utility)
    // Access only on queue.
    private var writable = false

    init(url: URL, io: IO = IO()) {
        self.url = url
        self.io = io
    }

    func load(completion: @escaping (LoadResult) -> Void) {
        queue.async { [self] in
            writable = false
            let data: Data
            do { data = try io.read(url) }
            catch {
                let error = error as NSError
                if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
                    writable = true
                    completion(.loaded([], warning: nil))
                } else {
                    // Includes protected-data lock, permissions and transient IO;
                    // none of these is evidence of malformed JSON.
                    completion(.blocked(.inaccessible))
                }
                return
            }
            do {
                let snapshots = try JSONDecoder().decode([UnifiedTask.Snapshot].self, from: data)
                writable = true
                completion(.loaded(snapshots, warning: nil))
            } catch {
                do {
                    try io.preserve(url)
                    writable = true
                    completion(.loaded([], warning: .corruptPreserved))
                } catch {
                    completion(.blocked(.preservationFailed))
                }
            }
        }
    }

    func save(_ snapshots: [UnifiedTask.Snapshot], completion: @escaping (Issue?) -> Void) {
        queue.async { [self] in
            guard writable else { completion(.notLoaded); return }
            do {
                let data = try JSONEncoder().encode(snapshots)
                try io.write(data, url)
                completion(nil)
            } catch {
                completion(.writeFailed)
            }
        }
    }
}
