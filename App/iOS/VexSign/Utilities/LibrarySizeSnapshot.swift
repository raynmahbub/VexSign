import Foundation

/// Directory walks run once per snapshot, off the UI thread, never inside a sort comparator.
enum LibrarySizeSnapshot {
    static let filesChanged = Notification.Name("VexSign.libraryFilesChanged")

    static func invalidate() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: filesChanged, object: nil)
        }
    }
    struct Entry: Sendable {
        let id: String
        let directory: URL
    }

    static func measure(_ entries: [Entry]) async throws -> [String: Int64] {
        let worker = Task.detached(priority: .utility) {
            var result: [String: Int64] = [:]
            for entry in entries {
                try Task.checkCancellation()
                if result[entry.id] == nil {
                    result[entry.id] = FileManager.default.allocatedSize(at: entry.directory)
                }
            }
            try Task.checkCancellation()
            return result
        }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            worker.cancel()
        }
    }
}
